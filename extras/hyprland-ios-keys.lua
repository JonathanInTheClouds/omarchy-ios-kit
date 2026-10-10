-- >>> omarchy-ios-kit keys >>>
-- SUPER+R / SUPER+SHIFT+R = run / debug the iOS app in VS Code (Omarchy with
-- the Lua Hyprland config). Appended to ~/.config/hypr/bindings.lua by the
-- kit's install.sh; remove this block to undo. Stock Omarchy doesn't use
-- these two keys.
-- In VS Code windows they send Ctrl+Alt+Shift+R / Ctrl+Alt+Shift+D, which the
-- kit's VS Code keybindings turn into "run on iPhone" / "debug" in iOS
-- projects (and Open Recent for SUPER+R elsewhere). Other windows: nothing.
local function ios_kit_is_vscode(window)
  local class = window and window.class or ""
  return class == "com.microsoft.VSCode" or class:lower() == "code" or class == "code-oss"
end

-- Explicit key down/up, as Omarchy's own clipboard bindings do (avoids
-- stuck keys).
local function ios_kit_send(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end

o.bind("SUPER + R", "Run iOS app (VS Code)", function()
  if ios_kit_is_vscode(hl.get_active_window()) then ios_kit_send("CTRL ALT SHIFT", "R") end
end)
o.bind("SUPER + SHIFT + R", "Debug iOS app (VS Code)", function()
  if ios_kit_is_vscode(hl.get_active_window()) then ios_kit_send("CTRL ALT SHIFT", "D") end
end)
-- <<< omarchy-ios-kit keys <<<
