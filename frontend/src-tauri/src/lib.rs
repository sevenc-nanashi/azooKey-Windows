mod ipc;

use serde::{Deserialize, Serialize};
use shared::AppConfig;
use std::{path::PathBuf, sync::Mutex};

#[derive(Debug)]
pub struct AppState {
    settings: Mutex<AppConfig>,
    ipc: Mutex<Option<ipc::IPCService>>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            settings: Mutex::new(AppConfig::new()),
            ipc: Mutex::new(None), // Lazy initialization - connect only when needed
        }
    }

    /// Get or create IPC connection. Returns None if connection fails.
    fn get_ipc(&self) -> Option<ipc::IPCService> {
        let mut ipc_guard = self.ipc.lock().ok()?;
        if ipc_guard.is_none() {
            // Try to connect
            match ipc::IPCService::new() {
                Ok(service) => {
                    *ipc_guard = Some(service);
                }
                Err(e) => {
                    eprintln!("Failed to connect to server: {}", e);
                    return None;
                }
            }
        }
        ipc_guard.clone()
    }
}

#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[tauri::command]
fn get_config(state: tauri::State<AppState>) -> AppConfig {
    let config = state.settings.lock().unwrap();
    config.clone()
}

#[tauri::command]
fn update_config(state: tauri::State<AppState>, new_config: AppConfig) -> Result<(), String> {
    let mut config = state.settings.lock().map_err(|e| e.to_string())?;
    *config = new_config;
    config.write();

    // Try to notify server of config update (non-fatal if server not running)
    if let Some(mut ipc) = state.get_ipc() {
        if let Err(e) = ipc.update_config() {
            eprintln!("Failed to notify server of config update: {}", e);
            // Don't fail - config was saved successfully
        }
    }
    Ok(())
}

#[derive(Debug, Deserialize, Serialize, Clone)]
struct Capability {
    cpu: bool,
    cuda: bool,
    vulkan: bool,
}

#[tauri::command]
fn check_capability() -> Capability {
    // cuda:
    // cudart64_12.dll
    // cublas64_12.dll

    // vulkan:
    // vulkan-1.dllの存在確認

    let mut capability = Capability {
        cpu: true,
        cuda: false,
        vulkan: false,
    };

    // Check for CUDA availability
    let cuda_files = ["cudart64_12.dll", "cublas64_12.dll"];
    let cuda_available = cuda_files.iter().all(|file| {
        // Check if the file exists in system path or in the current directory
        std::env::var("PATH")
            .unwrap_or_default()
            .split(';')
            .map(PathBuf::from)
            .chain(std::iter::once(std::env::current_dir().unwrap_or_default()))
            .any(|path| path.join(file).exists())
    });
    capability.cuda = cuda_available;

    // Check for Vulkan availability
    let vulkan_file = "vulkan-1.dll";
    let vulkan_available = std::env::var("PATH")
        .unwrap_or_default()
        .split(';')
        .map(PathBuf::from)
        .chain(std::iter::once(std::env::current_dir().unwrap_or_default()))
        .any(|path| path.join(vulkan_file).exists());
    capability.vulkan = vulkan_available;

    capability
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app_state = AppState::new();

    tauri::Builder::default()
        .manage(app_state)
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            greet,
            get_config,
            update_config,
            check_capability
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
