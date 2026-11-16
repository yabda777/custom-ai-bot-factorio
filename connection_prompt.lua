local windows_bridge_source = require("windows_bridge_source")

return function(player, code)
  local data = helpers.table_to_json{
    mod=script.mod_name, version=script.active_mods[script.mod_name],
    owner=player.name, pairing_code=code, host="127.0.0.1"
  }
  return "Подключи Sam к этому локальному ИИ-клиенту на Windows.\n"
    .. "Данные Factorio: "..data.."\n\n"
    .. [[Сервер Factorio уже запущен на этом компьютере. Подключайся к localhost через локальный RCON. Имя и пароль входа в мультиплеер для этого подключения не используются. Пароль и порт RCON мост прочитает из config.ini. Не выводи пароль в чат.

Создай %LOCALAPPDATA%\SamEngineer\mcp-windows.ps1 из блока PowerShell в конце этого сообщения. Запиши весь блок без Markdown-ограждения, в UTF-8. Для нестандартного профиля Factorio уточни путь к config.ini. Удали прежние настройки MCP для этого мода из конфигурации ИИ-клиента, если они указывают на старый мост.

Запусти скрипт через Windows PowerShell с аргументами -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File <полный путь к скрипту> -Setup. Для другого профиля передай -GameConfig <путь к config.ini>. Если RCON ещё не включён, попроси меня сохранить игру и закрыть Factorio. После настройки я снова открою карту через меню «Сетевая игра».

Зарегистрируй этот скрипт как локальный MCP-сервер sam_engineer в текущем клиенте. Команда и аргументы указаны в результате -Setup. Сохрани остальные настройки клиента. Если необходим перезапуск клиента, скажи об этом. Вызови status; если привязки ещё нет, вызови pair, передав pairing_code как строку, затем снова вызови status. Если код устарел, попроси меня открыть «Напарник → Данные для подключения» и скопировать новый. Сообщи результат и дождись моего игрового поручения.]]
    .. "\n\n```powershell\n" .. windows_bridge_source .. "```"
end
