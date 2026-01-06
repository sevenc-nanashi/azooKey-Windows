#Requires AutoHotkey v2.0
#SingleInstance Force

; Run as Administrator
if !A_IsAdmin {
    try {
        Run('*RunAs "' A_ScriptFullPath '"')
        ExitApp
    }
}

A_MaxHotkeysPerInterval := 350

; Left Ctrl up = English (IME OFF) - sends 0x97
~LCtrl Up::
{
    if (A_PriorKey = "LControl") {
        Send("{Ctrl up}{vk97}")
    }
}

; Right Ctrl up = Japanese (IME ON) - sends 0x98
~RCtrl Up::
{
    if (A_PriorKey = "RControl") {
        Send("{Ctrl up}{vk98}")
    }
}
