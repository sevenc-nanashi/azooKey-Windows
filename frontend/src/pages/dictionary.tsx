import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Book, Plus, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";
import { invoke } from "@tauri-apps/api/core";

interface DictionaryEntry {
    word: string;
    reading: string;
}

export const Dictionary = () => {
    const [entries, setEntries] = useState<DictionaryEntry[]>([]);
    const [newWord, setNewWord] = useState("");
    const [newReading, setNewReading] = useState("");

    // Load dictionary on component mount
    useEffect(() => {
        invoke<any>("get_config")
            .then((data) => {
                if (data.dictionary?.entries) {
                    setEntries(data.dictionary.entries);
                }
            })
            .catch(() => {
                // Keep default values if config fetch fails
            });
    }, []);

    const updateConfig = async (updater: (config: any) => void) => {
        try {
            const data = await invoke<any>("get_config");
            if (!data.dictionary) {
                data.dictionary = { entries: [] };
            }
            updater(data);
            await invoke("update_config", { newConfig: data });
            return data;
        } catch (error) {
            toast("設定の更新に失敗しました");
            return null;
        }
    };

    const handleAddWord = async () => {
        if (!newWord.trim() || !newReading.trim()) {
            toast("単語と読みを入力してください");
            return;
        }

        // Validate reading is hiragana (also allow prolonged sound mark ー)
        const hiraganaRegex = /^[\u3040-\u309F\u30FC]+$/;
        if (!hiraganaRegex.test(newReading)) {
            toast("読みはひらがなで入力してください（長音「ー」も使用可）");
            return;
        }

        // Check for duplicate
        if (entries.some((e) => e.word === newWord && e.reading === newReading)) {
            toast("この単語は既に登録されています");
            return;
        }

        const newEntry: DictionaryEntry = {
            word: newWord.trim(),
            reading: newReading.trim(),
        };

        const data = await updateConfig((config) => {
            config.dictionary.entries.push(newEntry);
        });

        if (data) {
            setEntries([...entries, newEntry]);
            setNewWord("");
            setNewReading("");
            toast("単語を登録しました");
        }
    };

    const handleDeleteWord = async (index: number) => {
        const data = await updateConfig((config) => {
            config.dictionary.entries.splice(index, 1);
        });

        if (data) {
            const newEntries = [...entries];
            newEntries.splice(index, 1);
            setEntries(newEntries);
            toast("単語を削除しました");
        }
    };

    const handleKeyDown = (e: React.KeyboardEvent) => {
        if (e.key === "Enter") {
            handleAddWord();
        }
    };

    return (
        <div className="space-y-8">
            <section className="space-y-2">
                <h1 className="text-sm font-bold text-foreground">ユーザー辞書</h1>
                <div className="space-y-4 rounded-md border p-4">
                    <div className="flex items-center space-x-4">
                        <Book />
                        <div className="flex-1 space-y-1">
                            <p className="text-sm font-medium leading-none">
                                単語を登録
                            </p>
                            <p className="text-xs text-muted-foreground">
                                変換候補に表示したい単語を登録します
                            </p>
                        </div>
                    </div>
                    <div className="flex gap-2">
                        <Input
                            placeholder="単語 (例: 東京都)"
                            value={newWord}
                            onChange={(e) => setNewWord(e.target.value)}
                            onKeyDown={handleKeyDown}
                            className="flex-1"
                        />
                        <Input
                            placeholder="読み (例: とうきょうと)"
                            value={newReading}
                            onChange={(e) => setNewReading(e.target.value)}
                            onKeyDown={handleKeyDown}
                            className="flex-1"
                        />
                        <Button onClick={handleAddWord} variant="secondary">
                            <Plus className="h-4 w-4 mr-1" />
                            追加
                        </Button>
                    </div>
                </div>
            </section>

            <section className="space-y-2">
                <h1 className="text-sm font-bold text-foreground">
                    登録済みの単語 ({entries.length})
                </h1>
                <div className="rounded-md border">
                    {entries.length === 0 ? (
                        <div className="p-4 text-center text-sm text-muted-foreground">
                            登録された単語はありません
                        </div>
                    ) : (
                        <div className="divide-y">
                            {entries.map((entry, index) => (
                                <div
                                    key={index}
                                    className="flex items-center justify-between p-3"
                                >
                                    <div className="flex gap-4">
                                        <span className="font-medium">{entry.word}</span>
                                        <span className="text-muted-foreground">
                                            {entry.reading}
                                        </span>
                                    </div>
                                    <Button
                                        variant="ghost"
                                        size="sm"
                                        onClick={() => handleDeleteWord(index)}
                                    >
                                        <Trash2 className="h-4 w-4 text-destructive" />
                                    </Button>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            </section>
        </div>
    );
};
