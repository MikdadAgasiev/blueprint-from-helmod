-- =============================================================
--  Blueprint from Helmod  –  data.lua
--  Factorio 2.0 API:
--    • ShortcutPrototype: icon/small_icon — строки, размер отдельно
--    • Иконки в __base__/graphics/icons/shortcut-toolbar/mip/
--    • CustomInputPrototype: без поля action (только у shortcut)
-- =============================================================

data:extend({
  -- Кнопка на панели инструментов
  {
    type            = "shortcut",
    name            = "bfh-open-gui",
    action          = "lua",
    localised_name  = {"shortcut.bfh-open-gui"},
    icon            = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x56.png",
    icon_size       = 56,
    small_icon      = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x24.png",
    small_icon_size = 24,
    style           = "blue",
  },
  -- Хоткей Ctrl+B
  {
    type         = "custom-input",
    name         = "bfh-open-gui-hotkey",
    key_sequence = "CONTROL + B",
  },
})

-- Preview arrows are decorative frames; their captions remain localized text.
for _,role in ipairs({'input','output'}) do for _,direction in ipairs({0,4,8,12}) do
 local vertical=direction==0 or direction==8;local w,h=vertical and 72 or 108,vertical and 60 or 38
 data.raw['gui-style'].default['bfh_preview_'..role..'_'..direction]={
  type='frame_style',parent='frame',width=w,height=h,padding=0,
  horizontal_align='center',vertical_align='center',
  graphical_set={base={filename='__blueprint-from-helmod__/graphics/ui/'..role..'-'..direction..'.png',position={0,0},size={w,h}}}
 }
end end
