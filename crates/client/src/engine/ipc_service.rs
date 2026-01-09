use anyhow::Result;
use hyper_util::rt::TokioIo;
use shared::proto::{
    azookey_service_client::AzookeyServiceClient, window_service_client::WindowServiceClient,
};
use std::{sync::Arc, time::Duration};
use tokio::{net::windows::named_pipe::ClientOptions, time};
use tonic::transport::Endpoint;
use tower::service_fn;
use windows::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY};

// Timeout for IPC calls to prevent indefinite hanging when server crashes
const IPC_TIMEOUT: Duration = Duration::from_millis(5000);
// Maximum time to wait for server to start (retries on file not found)
const MAX_CONNECT_RETRIES: u32 = 20;
const CONNECT_RETRY_DELAY: Duration = Duration::from_millis(100);

// connect to kkc server
#[derive(Debug, Clone)]
pub struct IPCService {
    // kkc server client
    azookey_client: AzookeyServiceClient<tonic::transport::channel::Channel>,
    // candidate window server client
    window_client: WindowServiceClient<tonic::transport::channel::Channel>,
    runtime: Arc<tokio::runtime::Runtime>,
}

#[derive(Debug, Clone, Default)]
pub struct Candidates {
    pub texts: Vec<String>,
    pub sub_texts: Vec<String>,
    pub hiragana: String,
    pub corresponding_count: Vec<i32>,
}

impl IPCService {
    pub fn new() -> Result<Self> {
        tracing::info!("IPCService::new() - Starting IPC connection");
        let runtime = tokio::runtime::Runtime::new()?;

        tracing::info!("IPCService::new() - Connecting to azookey_server pipe...");
        let server_channel = runtime.block_on(
            Endpoint::try_from("http://[::]:50051")?.connect_with_connector(service_fn(
                |_| async {
                    let mut retries = 0u32;
                    let client = loop {
                        match ClientOptions::new().open(r"\\.\pipe\azookey_server") {
                            Ok(client) => break client,
                            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32) => {
                                tracing::debug!("azookey_server pipe busy, retrying...");
                            }
                            // Retry on file not found (server not ready yet)
                            Err(e) if e.raw_os_error() == Some(ERROR_FILE_NOT_FOUND.0 as i32) => {
                                retries += 1;
                                tracing::debug!("azookey_server pipe not found, retry {}/{}", retries, MAX_CONNECT_RETRIES);
                                if retries >= MAX_CONNECT_RETRIES {
                                    tracing::error!("FAILED to connect to azookey_server pipe after {} retries: {:?}", retries, e);
                                    return Err(e);
                                }
                            }
                            Err(e) => {
                                tracing::error!("FAILED to connect to azookey_server pipe: {:?} (os_error: {:?})", e, e.raw_os_error());
                                return Err(e);
                            }
                        }

                        time::sleep(CONNECT_RETRY_DELAY).await;
                    };
                    tracing::info!("Successfully connected to azookey_server pipe");

                    Ok::<_, std::io::Error>(TokioIo::new(client))
                },
            )),
        )?;

        tracing::info!("IPCService::new() - Connecting to azookey_ui pipe...");
        let ui_channel = runtime.block_on(
            Endpoint::try_from("http://[::]:50052")?.connect_with_connector(service_fn(
                |_| async {
                    let mut retries = 0u32;
                    let client = loop {
                        match ClientOptions::new().open(r"\\.\pipe\azookey_ui") {
                            Ok(client) => break client,
                            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32) => {
                                tracing::debug!("azookey_ui pipe busy, retrying...");
                            }
                            // Retry on file not found (server not ready yet)
                            Err(e) if e.raw_os_error() == Some(ERROR_FILE_NOT_FOUND.0 as i32) => {
                                retries += 1;
                                tracing::debug!("azookey_ui pipe not found, retry {}/{}", retries, MAX_CONNECT_RETRIES);
                                if retries >= MAX_CONNECT_RETRIES {
                                    tracing::error!("FAILED to connect to azookey_ui pipe after {} retries: {:?}", retries, e);
                                    return Err(e);
                                }
                            }
                            Err(e) => {
                                tracing::error!("FAILED to connect to azookey_ui pipe: {:?} (os_error: {:?})", e, e.raw_os_error());
                                return Err(e);
                            }
                        }

                        time::sleep(CONNECT_RETRY_DELAY).await;
                    };
                    tracing::info!("Successfully connected to azookey_ui pipe");

                    Ok::<_, std::io::Error>(TokioIo::new(client))
                },
            )),
        )?;

        let azookey_client = AzookeyServiceClient::new(server_channel);
        let window_client = WindowServiceClient::new(ui_channel);
        tracing::info!("IPCService::new() - Successfully connected to both pipes");

        Ok(Self {
            azookey_client,
            window_client,
            runtime: Arc::new(runtime),
        })
    }
}

// implement methods to interact with kkc server
impl IPCService {
    #[tracing::instrument]
    pub fn append_text(&mut self, text: String) -> anyhow::Result<Candidates> {
        let request = tonic::Request::new(shared::proto::AppendTextRequest {
            text_to_append: text,
        });

        // Use timeout to prevent hanging when server crashes
        let mut client = self.azookey_client.clone();
        let response = self
            .runtime
            .clone()
            .block_on(async {
                match time::timeout(IPC_TIMEOUT, client.append_text(request)).await {
                    Ok(Ok(response)) => Ok(response),
                    Ok(Err(status)) => Err(anyhow::anyhow!("gRPC error: {}", status)),
                    Err(_elapsed) => Err(anyhow::anyhow!("IPC timeout: server may have crashed")),
                }
            })?;
        let composing_text = response.into_inner().composing_text;

        let candidates = if let Some(composing_text) = composing_text {
            Candidates {
                texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.text.clone())
                    .collect(),
                sub_texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.subtext.clone())
                    .collect(),
                hiragana: composing_text.hiragana,
                corresponding_count: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.corresponding_count)
                    .collect(),
            }
        } else {
            anyhow::bail!("composing_text is None");
        };

        Ok(candidates)
    }

    #[tracing::instrument]
    pub fn remove_text(&mut self) -> anyhow::Result<Candidates> {
        let request = tonic::Request::new(shared::proto::RemoveTextRequest {});
        let response = self
            .runtime
            .clone()
            .block_on(self.azookey_client.remove_text(request))?;
        let composing_text = response.into_inner().composing_text;

        let candidates = if let Some(composing_text) = composing_text {
            Candidates {
                texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.text.clone())
                    .collect(),
                sub_texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.subtext.clone())
                    .collect(),
                hiragana: composing_text.hiragana,
                corresponding_count: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.corresponding_count)
                    .collect(),
            }
        } else {
            anyhow::bail!("composing_text is None");
        };

        Ok(candidates)
    }

    #[tracing::instrument]
    pub fn clear_text(&mut self) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::ClearTextRequest {});
        let _response = self
            .runtime
            .clone()
            .block_on(self.azookey_client.clear_text(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn shrink_text(&mut self, offset: i32) -> anyhow::Result<Candidates> {
        let request = tonic::Request::new(shared::proto::ShrinkTextRequest { offset });
        let response = self
            .runtime
            .clone()
            .block_on(self.azookey_client.shrink_text(request))?;
        let composing_text = response.into_inner().composing_text;

        let candidates = if let Some(composing_text) = composing_text {
            Candidates {
                texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.text.clone())
                    .collect(),
                sub_texts: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.subtext.clone())
                    .collect(),
                hiragana: composing_text.hiragana,
                corresponding_count: composing_text
                    .suggestions
                    .iter()
                    .map(|s| s.corresponding_count)
                    .collect(),
            }
        } else {
            anyhow::bail!("composing_text is None");
        };

        Ok(candidates)
    }

    pub fn set_context(&mut self, context: String) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::SetContextRequest { context });
        let _response = self
            .runtime
            .clone()
            .block_on(self.azookey_client.set_context(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn learn_candidate(&mut self, candidate_index: i32) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::LearnCandidateRequest { candidate_index });
        let _response = self
            .runtime
            .clone()
            .block_on(self.azookey_client.learn_candidate(request))?;

        Ok(())
    }
}

// implement methods to interact with candidate window server
impl IPCService {
    #[tracing::instrument]
    pub fn show_window(&mut self) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::EmptyResponse {});
        self.runtime
            .clone()
            .block_on(self.window_client.show_window(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn hide_window(&mut self) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::EmptyResponse {});
        self.runtime
            .clone()
            .block_on(self.window_client.hide_window(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn set_window_position(
        &mut self,
        top: i32,
        left: i32,
        bottom: i32,
        right: i32,
    ) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::SetPositionRequest {
            position: Some(shared::proto::WindowPosition {
                top,
                left,
                bottom,
                right,
            }),
        });
        self.runtime
            .clone()
            .block_on(self.window_client.set_window_position(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn set_candidates(&mut self, candidates: Vec<String>) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::SetCandidateRequest { candidates });
        self.runtime
            .clone()
            .block_on(self.window_client.set_candidate(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn set_selection(&mut self, index: i32) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::SetSelectionRequest { index });
        self.runtime
            .clone()
            .block_on(self.window_client.set_selection(request))?;

        Ok(())
    }

    #[tracing::instrument]
    pub fn set_input_mode(&mut self, mode: &str) -> anyhow::Result<()> {
        let request = tonic::Request::new(shared::proto::SetInputModeRequest {
            mode: mode.to_string(),
        });
        self.runtime
            .clone()
            .block_on(self.window_client.set_input_mode(request))?;

        Ok(())
    }
}
