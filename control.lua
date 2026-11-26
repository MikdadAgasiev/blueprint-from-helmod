local local_allocation=require('local_allocation')
local flow_partition=require('flow_partition')
local junction_plan=require('junction_plan')
local block_boundaries=require('block_boundaries')
local parallel_solid=require('parallel_solid')
local three_solid=require('three_solid')
local resources=require('resources')
local quality_flows=require('quality_flows')
local transport_quality=require('transport_quality')
local container_distribution=require('container_distribution')
local beacon_planner=require('beacons')
local helmod_equipment=require('helmod_equipment')
local blueprint_text=require('blueprint_text')
local belt_contacts=require('belt_contacts')
local side_preview=require('side_preview')
local orientation=require('orientation')
local equipment_caption=require('equipment_caption')
local power_planner=require('power')
local final_outputs=require('final_outputs')
local output_flows=require('output_flows')
local flow_priorities=require('flow_priorities')
local production_groups=require('production_groups')
local lane_balance=require('lane_balance')
local gui_layout=require('gui_layout')
local equipment_catalog=require('equipment')
local entity_blacklist=require('entity_blacklist')
local fmf=require('fmf')
local layout_search=require('layout_search')
local layout_shape=require('layout_shape')
local furnace_arrays=require('furnace_arrays')
local progress_notice=require('progress_notice')
local tunnel_optimizer=require('tunnel_optimizer')
-- =============================================================
--  Blueprint from Helmod  –  control.lua  v0.5.0
--  Factorio 2.0+ API
--
--  Принципы:
--    • Работаем в целых клетках (top-left угол). В blueprint — центр.
--    • Размер машины: W, H из prototypes.entity[name].tile_width/_height.
--    • Шапка блока: sideloading через 2 сплиттера + подземка.
--    • 1 манипулятор на машину (сторону), расположен у нижнего ряда машины.
--    • Продукт идёт ВНИЗ, ингредиенты ВНИЗ.
--
--  Layout шапки (для 2 ингр., машины 3×3):
--    y=0:  входные ленты ↓ в (5,0) и (7,0)
--    y=1:  (5,1)+(6,1) верхний сплиттер ↓ | (7,1) подземка-вход ↓
--    y=2:  ГОРИЗОНТАЛЬНАЯ лента: (0..5) ←, (6..12) →, переходит в бок.ленты
--    y=3:  (5,3)+(6,3) нижний сплиттер ↑ | (7,3) подземка-выход ↓
--    y=4:  (6,4) ↑ | (7,4) ← (ингр.1 из подземки заходит в нижн.сплиттер)
--  Боковые ленты (y=2..body_end) в колонках 0 и 12, идут ↓
--
--  Тело блока:
--    Пара машин занимает H строк. Машины на пересечении колонок (2..2+W-1)
--    и (width-1-W..width-2). Манипулятор ВХОД в колонке 1 (и width-2),
--    манипулятор ВЫХОД в колонке mach_L+W (и mach_R-1).
--    Стоит манипулятор в последней строке машины (y = mach_top + H - 1).
--    Центральный конвейер продукта идёт вниз от y=body_start до низа.
-- =============================================================

local external_inputs=require("external_inputs")
local direct_solid=require("direct_solid")
local layout_planner=require("layout")
local fluid_planner=require("fluids")
local validator=require("validation")
local belt_validator=require("belt_validation")
local plan_validator=require("plan_validation")
local production_reserve=require("production_reserve")
local capacity_planner=require("capacity")
local GUI_NAME = "bfh_main_frame"
local router = require("routing")
local ug_pairing=require('ug_pairing')
local display_plates=require("display_plates")
local generation_work=require("generation_work")
local transfer_planner=require("transfer")
local many_solid=require("many_solid")
local launch_products=require("launch_products")

local _diag_player = nil
local _diag_log_buffer = nil  -- nil или таблица строк (по строке за вызов)
local _diag_log_filename = "bfh-routing.log"
local _diag_trial=false
local _diag_trial_logs=nil

-- Подробная диагностика сохраняется в файл; итоговые сообщения выводит GUI.
-- В конце build_blueprint_entities буфер сбрасывается в script-output/bfh-routing.log.
local function _diag_log(s)
  if _diag_trial then _diag_trial_logs[#_diag_trial_logs+1]=s;return end
  if _diag_log_buffer then _diag_log_buffer[#_diag_log_buffer + 1] = s end
end

local _capacity_warned={}
local function warn_capacity(recipe,detail)
  recipe=recipe or "unknown"
  _diag_log("[BFH-capacity] LIMIT "..tostring(recipe)..": "..detail)
  if _diag_player and not _capacity_warned[recipe] then
    _diag_player.print({"bfh.capacity-incomplete",recipe})
  end
  _capacity_warned[recipe]=true
end

local function _diag_log_flush()
  if _diag_log_buffer and helpers and helpers.write_file then
    helpers.write_file(_diag_log_filename, table.concat(_diag_log_buffer, "\n") .. "\n", false)
    _diag_log_buffer = nil
  end
end


-- Rebuild from this force's unlocked recipes; prototype existence is insufficient.
local function get_belt_items(force,items)
  local result=equipment_catalog.entities(force,'transport-belt',items)
  table.sort(result,function(a,b)
    local x,y=prototypes.entity[a].belt_speed,prototypes.entity[b].belt_speed
    if x~=y then return x<y end
    return a<b
  end)
  return result
end

-- Research is force-specific and can change while a save is running.
local function get_pipe_items(force)
  local result={}
  for _,name in ipairs(equipment_catalog.entities(force,'pipe')) do
    local p=prototypes.entity[name];local item=p.items_to_place_this[1] and prototypes.item[p.items_to_place_this[1].name]
    if item and (not item.group or item.group.name~='color-coded-pipes') then result[#result+1]=name end
  end
  return result
end

-- По выбранной трубе находит соответствующую подземную трубу (pipe-to-ground).
-- Через related-прототип или по имени. Падает на ванильную "pipe-to-ground".
local function to_pipe_underground(pipe_name)
  local p = prototypes.entity[pipe_name]
  -- Эвристика по имени: заменяем "pipe" → "pipe-to-ground"
  if pipe_name == "pipe" then return "pipe-to-ground" end
  -- модовые: часто "<prefix>-pipe" → "<prefix>-pipe-to-ground"
  local guess = pipe_name:gsub("%-pipe$", "-pipe-to-ground")
  if guess ~= pipe_name and prototypes.entity[guess] then return guess end
  guess = pipe_name .. "-to-ground"
  if prototypes.entity[guess] then return guess end
  -- ищем любой pipe-to-ground с тем же префиксом
  local prefix = pipe_name:gsub("pipe.*$", "")
  local ok, ugs = pcall(function()
    return prototypes.get_entity_filtered({ { filter = "type", type = "pipe-to-ground" } })
  end)
  if ok and ugs then
    for name, _ in pairs(ugs) do
      if prefix ~= "" and name:sub(1, #prefix) == prefix then return name end
    end
  end
  return "pipe-to-ground"
end

-- ── Универсальный поиск сплиттера/подземки по ленте ────────────
-- Сначала пытаемся через прототипы (работает для любых модовых лент: turbo, Bob's,
-- Schall, Ultimate, и т.д.). Падаем на хардкод-таблицу для совместимости.

local SPLITTER_MAP = {
  ["transport-belt"]         = "splitter",
  ["fast-transport-belt"]    = "fast-splitter",
  ["express-transport-belt"] = "express-splitter",
  ["turbo-transport-belt"]   = "turbo-splitter",
}
local UG_MAP = {
  ["transport-belt"]         = "underground-belt",
  ["fast-transport-belt"]    = "fast-underground-belt",
  ["express-transport-belt"] = "express-underground-belt",
  ["turbo-transport-belt"]   = "turbo-underground-belt",
}

-- Кэш чтобы не дёргать prototypes на каждый вызов
local _splitter_cache = {}
local _ug_cache = {}
local _ug_dist_cache = {}

local function to_underground(b)
  if _ug_cache[b] ~= nil then return _ug_cache[b] end
  -- 1) Хардкод-таблица
  local res = UG_MAP[b]
  if res and prototypes.entity[res] then
    _ug_cache[b] = res
    return res
  end
  -- 2) Поиск через related_underground_belt в прототипе ленты
  local belt_proto = prototypes.entity[b]
  if belt_proto and belt_proto.related_underground_belt then
    res = belt_proto.related_underground_belt.name
    _ug_cache[b] = res
    return res
  end
  -- 3) Поиск через имя: <prefix>-underground-belt
  -- Например "ub-mk2-belt" → "ub-mk2-underground-belt" (не всегда работает, но попробуем)
  local guess = b:gsub("transport%-belt", "underground-belt")
  if guess ~= b and prototypes.entity[guess] then
    _ug_cache[b] = guess
    return guess
  end
  guess = b:gsub("%-belt$", "-underground-belt")  -- ultra-fast-belt → ultra-fast-underground-belt
  if guess ~= b and prototypes.entity[guess] then
    _ug_cache[b] = guess
    return guess
  end
  guess = b .. "-underground"
  if prototypes.entity[guess] then
    _ug_cache[b] = guess
    return guess
  end
  -- 4) Fallback на ваниль
  _ug_cache[b] = "underground-belt"
  return "underground-belt"
end

local function to_splitter(b)
  if _splitter_cache[b] ~= nil then return _splitter_cache[b] end
  local res = SPLITTER_MAP[b]
  if res and prototypes.entity[res] then
    _splitter_cache[b] = res
    return res
  end
  -- Перебор кандидатов замены имени ленты на сплиттер (разные моды называют по-разному):
  --   "...transport-belt" → "...splitter"   (ваниль, se-space)
  --   "...belt"           → "...splitter"   (ultra-fast-belt → ultra-fast-splitter)
  local candidates = {
    b:gsub("transport%-belt", "splitter"),
    b:gsub("%-belt$", "-splitter"),
    b:gsub("belt", "splitter"),
  }
  for _, guess in ipairs(candidates) do
    if guess ~= b and prototypes.entity[guess] then
      _splitter_cache[b] = guess
      return guess
    end
  end
  -- Fallback
  _splitter_cache[b] = "splitter"
  return "splitter"
end

-- Возвращает максимальную длину тоннеля (между входом и выходом) для подземки.
-- Расстояние между центрами входа и выхода. Fallback: 5/7/9 по типу ленты.
local function get_underground_max_distance(belt_in)
  if _ug_dist_cache[belt_in] ~= nil then return _ug_dist_cache[belt_in] end
  local ug_name = to_underground(belt_in)
  local ug_proto = prototypes.entity[ug_name]
  if ug_proto and ug_proto.max_underground_distance then
    -- Engine-verified: basic underground mouths can be 5 tiles apart.
    local d = ug_proto.max_underground_distance
    _ug_dist_cache[belt_in] = d
    return d
  end
  -- Fallback: hardcoded values
  local d = 5
  if belt_in == "fast-transport-belt" then d = 7
  elseif belt_in == "express-transport-belt" then d = 9
  elseif belt_in == "turbo-transport-belt" then d = 11
  end
  _ug_dist_cache[belt_in] = d
  return d
end

-- ── Размер сущности ──────────────────────────────────────────
local function get_entity_size(name)
  local p = prototypes.entity[name]
  if not p then return 3, 3 end
  local tw, th = p.tile_width, p.tile_height
  if tw and th and tw > 0 and th > 0 then return tw, th end
  local b = p.collision_box or p.selection_box
  if b then
    local w = math.ceil(b.right_bottom.x - b.left_top.x - 0.01)
    local h = math.ceil(b.right_bottom.y - b.left_top.y - 0.01)
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end
    return w, h
  end
  return 3, 3
end

-- Читает точки подключения жидкости (pipe connections) из прототипа машины.
-- Возвращает список { {dx, dy, dir, kind}, ... } — смещения относительно ЛЕВОГО-ВЕРХНЕГО
-- угла машины (в клетках), направление трубы наружу, kind = production_type.
-- Учитывает поворот машины. Если прототип не отдаёт коннекшены — пустой список.
local function get_fluid_connections(mach_name, W, H, direction)
  local p = prototypes.entity[mach_name]
  if not p or not p.fluidbox_prototypes then return {} end
  local result = {}
  local cx = W / 2
  local cy = H / 2
  for _, fb in pairs(p.fluidbox_prototypes) do
    local pc = fb.pipe_connections
    if pc then
      for _, conn in pairs(pc) do
        local pos = nil
        if conn.positions then
          local idx = (direction == 0 and 1) or (direction == 4 and 2)
                   or (direction == 8 and 3) or (direction == 12 and 4) or 1
          pos = conn.positions[idx] or conn.positions[1]
        elseif conn.position then
          pos = { x = conn.position.x, y = conn.position.y }
        end
        if pos then
          local dx = math.floor(cx + pos.x)
          local dy = math.floor(cy + pos.y)
          -- Corner coordinates lie on two faces; the prototype owns the face.
          local out_dir = conn.direction and (conn.direction + direction) % 16
          if out_dir == nil then
            if pos.y <= -cy + 0.5 then out_dir = 0
            elseif pos.y >= cy - 0.5 then out_dir = 8
            elseif pos.x <= -cx + 0.5 then out_dir = 12
            elseif pos.x >= cx - 0.5 then out_dir = 4
            else out_dir = 8 end
          end
          result[#result+1] = {
            dx = dx, dy = dy, dir = out_dir,
            kind = (fb.production_type or "input"),
          }
        end
      end
    end
  end
  return result
end

-- ── Конвертация top-left клетки → центр для blueprint ────────
-- Возвращает позицию центра сущности размера (w, h), стоящей в клетке top-left (cx, cy).
-- Для машины 3×3 в клетке (2,5): center = (2 + 3/2, 5 + 3/2) = (3.5, 6.5)?
-- Нет! Центр 3×3 = клетка в середине = (cx+1, cy+1). Для 2×2 центр между клетками = (cx+1, cy+1).
-- Общая формула: center = (cx + w/2, cy + h/2) для ЛЮБОГО размера — центр геометрического квадрата.
-- Проверка для 3×3: занимает клетки [cx, cx+1, cx+2]. Границы: [cx, cx+3]. Центр = cx+1.5.
-- НО! В Factorio координаты сущностей в blueprint — это координаты плиточной сетки,
-- где 0,0 — это ЛЕВЫЙ-ВЕРХНИЙ угол клетки (0,0), а клетка (0,0) занимает [0..1, 0..1].
-- Значит центр клетки (0,0) = (0.5, 0.5).
-- Для машины 3×3 в клетках (2,5)..(4,7): занимает геометрический [2..5, 5..8], центр = (3.5, 6.5).
--
-- Проверка: в blueprint для "assembling-machine-2" позиция (3.5, 6.5) — это машина,
-- занимающая клетки 2,3,4 по X и 5,6,7 по Y? Да, так и есть.
--
-- Для 2×2 в клетках (2,5)..(3,6): центр = (3, 6) — целое число. ✓
-- Для 1×1 в клетке (2,5): центр = (2.5, 5.5). ✓
local function cell_to_center(cx, cy, w, h)
  return cx + w / 2, cy + h / 2
end

-- ── Утилиты ──────────────────────────────────────────────────

local function helmod_available()
  return remote.interfaces["helmod_interface"] ~= nil
    and remote.interfaces["helmod_interface"]["get_models"] ~= nil
end

local function default_settings()
  return {
    belt_in      = "transport-belt",
    belt_out     = "transport-belt",
    inserter_in  = "fast-inserter",
    inserter_out = "fast-inserter",
    link_mode    = "direct",
    use_display_plates = false,
    transfer_mode="multiple",
    transport_quality="normal",
    entity_blacklist={},
    generation_load="normal",
    reserve_percent=0,
    loader_name="auto",
    distribution_mode="belts",
    container_name="auto",
    use_power=true,
    pole_name="auto",
    fluid_mode="ordinary",
    layout_search="normal",
    layout_shape="auto",
  }
end

local function get_settings(pi)
  if not storage.bfh_settings then storage.bfh_settings = {} end
  if not storage.bfh_settings[pi] then
    storage.bfh_settings[pi] = default_settings()
  end
  return storage.bfh_settings[pi]
end

local function entity_exists(n) return n and prototypes.entity[n] ~= nil end

-- Manufacturing equipment belongs to the Helmod plan, never to a global fallback.
local function get_machine_name(rn, cache)
  local name=rn.factory and rn.factory.name
  if entity_exists(name) then return name end
  error('Helmod machine unavailable: '..tostring(name)..' / '..tostring(rn.name),0)
end

local function get_machine_count(rn)
  local c = rn.factory and rn.factory.count
  if c and c > 0 then return math.max(1,math.ceil(c-1e-9)) end
  return 1
end

local function get_ingredient_names(rn)
  local r, seen = {}, {}
  local function add(n)
    if n and not seen[n] then seen[n] = true; r[#r+1] = n end
  end
  if rn.ingredients then
    for _, ing in pairs(rn.ingredients) do
      if ing.type ~= "fluid" then add(ing.name) end
    end
  end
  if #r == 0 and rn.name then
    local p = prototypes.recipe[rn.name]
    if p then
      for _, ing in pairs(p.ingredients) do
        if ing.type ~= "fluid" then add(ing.name) end
      end
    end
  end
  return r
end

-- Возвращает true если у рецепта есть жидкий ингредиент
local function has_fluid_ingredient(rn)
  if rn.ingredients then
    for _, ing in pairs(rn.ingredients) do
      if ing.type == "fluid" then return true end
    end
  end
  if rn.name then
    local p = prototypes.recipe[rn.name]
    if p then
      for _, ing in pairs(p.ingredients) do
        if ing.type == "fluid" then return true end
      end
    end
  end
  return false
end

-- ── Тип разводки жидкости у машины ──
-- Для машин 3×3 с жидким входом в Factorio есть два варианта расположения точек соединения:
--   "centre" — assembling-machine-2/3, oil-refinery входы и т.п.: труба соединяется с
--              ЦЕНТРОМ грани (y_off=0). Стандарт для большинства сборщиков.
--   "edges"  — chemical-plant: 2 жидких входа на 1-й и 3-й клетках грани (y_off=±1),
--              средняя клетка свободна для манипулятора твёрдого ингредиента.
-- Аналогично может быть для выходов (но в ваниле только химзавод имеет выходы edges).
local CHEMPLANT_LIKE = {
  ["chemical-plant"] = true,
  -- сюда же могут добавляться модовые аналоги
}

local function is_chemplant_like(mach_name)
  return CHEMPLANT_LIKE[mach_name] == true
end

-- ── Helpers для нефтезавода (vertical fluid pillar) ──
-- Возвращают списки жидких ингредиентов и продуктов рецепта (имена)
local function get_fluid_ingredients(rn)
  local r, seen = {}, {}
  local function add(n) if n and not seen[n] then seen[n] = true; r[#r+1] = n end end
  if rn.ingredients then
    for _, ing in pairs(rn.ingredients) do
      if ing.type == "fluid" then add(ing.name) end
    end
  end
  if #r == 0 and rn.name then
    local p = prototypes.recipe[rn.name]
    if p then
      for _, ing in pairs(p.ingredients) do
        if ing.type == "fluid" then add(ing.name) end
      end
    end
  end
  return r
end

local function get_fluid_products(rn)
  local r, seen = {}, {}
  local function add(n) if n and not seen[n] then seen[n] = true; r[#r+1] = n end end
  if rn.products then
    for _, p in pairs(rn.products) do
      if p.type == "fluid" then add(p.name) end
    end
  end
  if #r == 0 and rn.name then
    local pr = prototypes.recipe[rn.name]
    if pr and pr.products then
      for _, p in pairs(pr.products) do
        if p.type == "fluid" then add(p.name) end
      end
    end
  end
  return r
end

local function get_solid_products(rn)
  local r, seen = {}, {}
  local function add(n) if n and not seen[n] then seen[n] = true; r[#r+1] = n end end
  if rn.products then
    for _, p in pairs(rn.products) do
      if p.type ~= "fluid" then add(p.name) end
    end
  end
  if #r == 0 and rn.name then
    local pr = prototypes.recipe[rn.name]
    if pr and pr.products then
      for _, p in pairs(pr.products) do
        if p.type ~= "fluid" then add(p.name) end
      end
    end
  end
  return r
end

local function idx_of(t, v)
  for i, x in ipairs(t) do if x == v then return i end end
  return 1
end

-- ── Расчёт пропускной способности и числа подблоков ──
--
-- belt_throughput(belt_name): максимальная пропускная способность ленты в items/sec
-- для обеих дорожек. Для жёлтой/красной/синей/turbo это 15/30/45/60 соответственно.
-- В Factorio prototype.entity[belt].belt_speed = тайлов/тик. Throughput = belt_speed * 480
-- (= belt_speed * 60 тиков/сек * 8 предметов/тайл = 480) для обеих дорожек.
local function belt_throughput(belt_name)
  local p = prototypes.entity[belt_name]
  if not p or not p.belt_speed then return 15 end  -- fallback: жёлтая
  return p.belt_speed * 480
end

-- The input and output constraints use independent selected belt prototypes.
local function get_flow_per_sec(item,rn)
  return capacity_planner.flow(item,rn)
end
local function compute_split_count(rn,settings)
  return capacity_planner.split(rn,settings,get_machine_count(rn))
end

-- ── add_entity (работает с top-left клетками) ────────────────
--
-- cell_x, cell_y — ТОП-ЛЕВЫЙ угол клетки сущности в координатах блока.
-- w, h — размер в клетках. Для 1×1 не указывать.
local function add_entity_cell(list, en, name, cell_x, cell_y, w, h, dir, extra, offset_x, offset_y)
  w = w or 1
  h = h or 1
  local cx, cy = cell_to_center(cell_x + offset_x, cell_y + offset_y, w, h)
  local e = {
    entity_number = en,
    name          = name,
    position      = { x = cx, y = cy },
    direction     = dir or defines.direction.north,
  }
  if extra then
    for k, v in pairs(extra) do e[k] = v end
  end
  list[#list + 1] = e
  return en + 1
end

-- ── Шапка блока для 2 ингредиентов ───────────────────────────
--
-- По схеме из редактора:
--   (5,0)  лента ↓ (ингр.2)
--   (7,0)  лента ↓ (ингр.1)
--   (5,1)+(6,1)  верхний сплиттер ↓
--   (7,1)  подземка-вход ↓
--   (0..5, 2) горизонтальная лента ←
--   (6..12, 2) горизонтальная лента →
--   (5,3)+(6,3)  нижний сплиттер ↑
--   (7,3)  подземка-выход ↓
--   (6,4)  лента ↑
--   (7,4)  лента ←
--
-- Но это для ширины 13. Для переменной ширины надо пересчитать.
-- Универсализация: "левая половина" шапки зеркально от "правой".
-- Центр шапки = (width-1)/2 если width нечётная, или между клетками.
--
-- Для простоты: работаем с width=13 жёстко в v0.5.0. Машины только 3×3.
-- Потом обобщим.

local HEADER_HEIGHT = 3  -- y=0..2 — собственно шапка ДО машин.
                         -- На y=3,4 шапка частично перекрывается с первыми машинами:
                         --   y=3: нижний сплиттер ↑ (5..6), подземка-выход ↓ (7) —
                         --        в столбцах НЕ занятых машинами (машины в 2..4 и 8..10)
                         --   y=4: лента ↑ (6) и лента ← (7) — для разворота ингр.1

local function build_header_2ing(width, belt_in, offset_x, offset_y, en, list)
  local splitter = to_splitter(belt_in)
  local ug_belt  = to_underground(belt_in)

  if not entity_exists(splitter) then splitter = "splitter" end
  if not entity_exists(ug_belt)  then ug_belt  = "underground-belt" end

  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  -- Позиции зависят от ширины блока (которая зависит от размера машины).
  -- Сплиттер по центру: c_split_L = (width-1)//2 - 1 для нечётной ширины.
  -- Для width=13: c_split_L=5 (сплиттер на колонках 5,6) ✓
  -- Для width=11: c_split_L=4 (сплиттер на колонках 4,5)
  local c_split_L = math.floor((width - 1) / 2) - 1
  local c_in2     = c_split_L          -- вход ингр.2 над левой клеткой сплиттера
  local c_in1     = c_split_L + 2      -- вход ингр.1 справа от сплиттера (через подземку)

  -- ── y=0: входные ленты (по одной клетке) ──────────────────
  en = add_entity_cell(list, en, belt_in, c_in2, 0, 1, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_in1, 0, 1, 1, dir_s, nil, offset_x, offset_y)

  -- ── y=1: верхний сплиттер ↓ + подземка-вход ↓ ─────────────
  en = add_entity_cell(list, en, splitter, c_split_L, 1, 2, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_in1, 1, 1, 1, dir_s, { type = "input" }, offset_x, offset_y)

  -- ── y=2: горизонтальная лента ─────────────────────────────
  -- В углах (0,2) и (width-1,2) — поворот с горизонтали на юг (это уже начало боковых лент).
  -- Слева ← от 1 до c_split_L, справа → от c_split_L+1 до width-2.
  for x = 0, c_split_L do
    local d = (x == 0) and dir_s or dir_w
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, d, nil, offset_x, offset_y)
  end
  for x = c_split_L + 1, width - 1 do
    local d = (x == width - 1) and dir_s or dir_e
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, d, nil, offset_x, offset_y)
  end

  -- ── y=3: нижний сплиттер ↑ + подземка-выход ↓ ─────────────
  -- На этой y ТАКЖЕ начинается верхний ряд первых машин (в столбцах 2..4 и 8..10).
  -- Сплиттер занимает столбцы c_split_L и c_split_L+1 (= 5,6 для width=13) —
  -- эти столбцы свободны от машин, поэтому нет конфликта.
  en = add_entity_cell(list, en, splitter, c_split_L, 3, 2, 1, dir_n, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_in1, 3, 1, 1, dir_s, { type = "output" }, offset_x, offset_y)

  -- ── y=4: заворот ингр.1 ───────────────────────────────────
  -- (c_split_L+1, 4) — лента ↑ (ингр.1 идёт вверх в нижний сплиттер)
  -- (c_in1,        4) — лента ← (ингр.1 из подземки заворачивает влево к ленте ↑)
  -- На y=4 одновременно стоит верхний-средний ряд машин (но не в этих столбцах).
  en = add_entity_cell(list, en, belt_in, c_split_L + 1, 4, 1, 1, dir_n, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_in1, 4, 1, 1, dir_w, nil, offset_x, offset_y)

  -- ── Боковые ленты y=3 ──
  -- ВАЖНО: НЕ ставим — body_start для H≥3 равен 3, и build_body уже
  -- кладёт боковые ленты в столбцах 0 и width-1 начиная с y=body_y.
  -- Если поставить здесь — будет коллизия (две ленты в одной клетке).
  -- Для H<3 тело начинается ниже; build_block заполняет переход от шапки.

  return en
end

-- ── Шапка для 1 ингредиента ──────────────────────────────────
-- Просто: (центр, 0) вход → (центр, 1) сплиттер → лента y=2 расходится.
local function build_header_1ing(width, belt_in, offset_x, offset_y, en, list)
  local splitter = to_splitter(belt_in)
  if not entity_exists(splitter) then splitter = "splitter" end

  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  local c_split = math.floor((width - 1) / 2) - 1  -- сплиттер по центру блока

  -- y=0: входная лента ↓
  en = add_entity_cell(list, en, belt_in, c_split, 0, 1, 1, dir_s, nil, offset_x, offset_y)

  -- y=1: сплиттер ↓ (1×2)
  en = add_entity_cell(list, en, splitter, c_split, 1, 2, 1, dir_s, nil, offset_x, offset_y)

  -- y=2: горизонтальная лента (с поворотами на юг по краям)
  for x = 0, c_split do
    local d = (x == 0) and dir_s or dir_w
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, d, nil, offset_x, offset_y)
  end
  for x = c_split + 1, width - 1 do
    local d = (x == width - 1) and dir_s or dir_e
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, d, nil, offset_x, offset_y)
  end

  return en
end

-- ── Шапка для 3-4 ингредиентов ───────────────────────────────
--
-- Воспроизводит точную эталонную схему (декодированную из blueprint string).
-- Высота шапки = 6 клеток (y=0..5). Ширина блока = 2*W + 9.
--
-- Для W=3, ширина=15. Координаты столбцов:
--   c_in_2  = 2  (вход ингр.2 — в верхний сплиттер)
--   c_in_1  = 4  (вход ингр.1 — в подземку)
--   c_in_4  = 6  (вход ингр.4 — в правый сплиттер)
--   c_in_3  = 8  (вход ингр.3 — в правую подземку)
--   c_split_L_left = 2..3  (левый сплиттер)
--   c_split_R_left = 6..7  (правый сплиттер)
--   c_ug_L = 4 (вертикальная подземка ингр.2 в левой шапке)
--   c_ug_R = 8 (вертикальная подземка ингр.4 в правой шапке)
--   c_horiz_in  = 5  (горизонтальные подземки на y=2 и y=4)
--   c_horiz_out_L = 1
--   c_horiz_out_R = 10
--
local function build_header_34ing(width, W, belt_in, offset_x, offset_y, en, list)
  local splitter = to_splitter(belt_in)
  local ug_belt  = to_underground(belt_in)
  if not entity_exists(splitter) then splitter = "splitter" end
  if not entity_exists(ug_belt)  then ug_belt  = "underground-belt" end

  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  -- Универсальные координаты, рассчитанные от ширины блока и размера машины.
  -- Для 3-4 ингр.: width = 2*W + 9
  -- Для W=3, width=15:
  --   c_mach_L_left=3, c_mach_R_left=9 (top-left верхних углов машин)
  --   Левая шапка: сплиттеры на (2,3), вход ингр.1 на 4
  --   Правая шапка: сплиттеры на (6,7), вход ингр.3 на 8
  --
  local c_mach_L_left = 3                  -- top-left левой машины (всегда 3 для 3-4 ингр.)
  local c_mach_R_left = width - 3 - W      -- top-left правой машины. Для W=3: 15-3-3=9 ✓

  local c_split_L_L = c_mach_L_left - 1    -- = 2 (левая клетка левого сплиттера)
  local c_in_2      = c_split_L_L          -- = 2 (вход ингр.2)
  local c_in_1      = c_split_L_L + 2      -- = 4 (вход ингр.1)

  local c_split_R_L = c_mach_R_left - 3    -- = 6 (левая клетка правого сплиттера)
  local c_in_4      = c_split_R_L          -- = 6 (вход ингр.4)
  local c_in_3      = c_split_R_L + 2      -- = 8 (вход ингр.3)

  local c_h_ug_L = c_in_1 + 1              -- = 5 (горизонтальная подземка вход)
  local c_h_ug_R = c_in_3 + 2              -- = 10 (горизонтальная подземка выход)

  local c_inner_L = 1
  local c_inner_R = width - 2              -- = 13

  -- ═══ y=0: входные ленты ═══
  en = add_entity_cell(list, en, belt_in, c_in_2, 0, 1, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_in_1, 0, 1, 1, dir_s, nil, offset_x, offset_y)

  -- ═══ y=1: верхний сплиттер ИНГР.1+2 ═══
  -- Сплиттер 2×1 на столбцах (c_split_L_L, c_split_L_L+1), направление юг
  en = add_entity_cell(list, en, splitter, c_split_L_L, 1, 2, 1, dir_s, nil, offset_x, offset_y)
  -- Подземка-вход для ингр.1 (ныряет под наземку ингр.2)
  en = add_entity_cell(list, en, ug_belt, c_in_1, 1, 1, 1, dir_s, { type = "input" }, offset_x, offset_y)

  -- ═══ y=2: горизонтальная лента ингр.1+2 + входы ингр.3+4 + горизонт.подземка ═══
  -- Слева идёт лента ←, справа лента →. В углах (c_inner_L, c_inner_R) — поворот вниз.
  en = add_entity_cell(list, en, belt_in, c_inner_L, 2, 1, 1, dir_s, nil, offset_x, offset_y)
  for x = c_split_L_L, c_h_ug_L - 1 do
    -- от сплиттера до входа в горизонт.подземку
    local d = (x < c_split_L_L + 1) and dir_w or dir_e
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, d, nil, offset_x, offset_y)
  end
  -- Левая часть y=2 (запад): между c_inner_L и c_split_L_L все ленты ←
  for x = c_inner_L + 1, c_split_L_L - 1 do
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, dir_w, nil, offset_x, offset_y)
  end
  -- Горизонтальная подземка-вход на (c_h_ug_L, 2) направление east (ныряет под правую шапку)
  local east_mouth = c_split_R_L - 1
  for x = c_h_ug_L, east_mouth - 1 do
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, dir_e, nil, offset_x, offset_y)
  end
  en = add_entity_cell(list, en, ug_belt, east_mouth, 2, 1, 1, dir_e, { type = "input" }, offset_x, offset_y)
  -- Входы ингр.3 и ингр.4 — на y=2
  en = add_entity_cell(list, en, belt_in, c_in_4, 2, 1, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_in_3, 2, 1, 1, dir_s, nil, offset_x, offset_y)
  -- Горизонтальная подземка-выход на (c_h_ug_R, 2) направление east (выныривает после правой шапки)
  en = add_entity_cell(list, en, ug_belt, c_h_ug_R, 2, 1, 1, dir_e, { type = "output" }, offset_x, offset_y)
  -- После выхода идёт лента →
  for x = c_h_ug_R + 1, c_inner_R - 1 do
    en = add_entity_cell(list, en, belt_in, x, 2, 1, 1, dir_e, nil, offset_x, offset_y)
  end
  en = add_entity_cell(list, en, belt_in, c_inner_R, 2, 1, 1, dir_s, nil, offset_x, offset_y)

  -- ═══ y=3: нижний сплиттер ИНГР.1+2 + подземка-выход + правый верхний сплиттер ИНГР.3+4 ═══
  -- Подземка-вход в столбце 1 (ингр.1+2 идущая вниз ныряет, чтобы пропустить ингр.3+4 на y=4)
  en = add_entity_cell(list, en, ug_belt, c_inner_L, 3, 1, 1, dir_s, { type = "input" }, offset_x, offset_y)
  en = add_entity_cell(list, en, splitter, c_split_L_L, 3, 2, 1, dir_n, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_in_1, 3, 1, 1, dir_s, { type = "output" }, offset_x, offset_y)
  -- Правый верхний сплиттер для ингр.3+4 (направление юг)
  en = add_entity_cell(list, en, splitter, c_split_R_L, 3, 2, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_in_3, 3, 1, 1, dir_s, { type = "input" }, offset_x, offset_y)
  -- Подземка-вход в столбце c_inner_R (зеркально левой)
  en = add_entity_cell(list, en, ug_belt, c_inner_R, 3, 1, 1, dir_s, { type = "input" }, offset_x, offset_y)

  -- ═══ y=4: завороты ингр.1, горизонтальная лента ингр.3+4 ═══
  en = add_entity_cell(list, en, belt_in, 0, 4, 1, 1, dir_s, nil, offset_x, offset_y)
  -- Подземка-выход в столбце 1 направлением запад (выпускает ингр.3+4 на боковую ленту)
  en = add_entity_cell(list, en, ug_belt, c_inner_L, 4, 1, 1, dir_w, { type = "output" }, offset_x, offset_y)
  -- Заворот ингр.1 (от подземки-выход (c_in_1, 3) идёт лента ← на (c_in_1, 4) и ↑ на (c_in_1-1, 4))
  en = add_entity_cell(list, en, belt_in, c_in_1 - 1, 4, 1, 1, dir_n, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_in_1, 4, 1, 1, dir_w, nil, offset_x, offset_y)
  -- Горизонтальная подземка-вход (c_h_ug_L, 4) на запад (ингр.3+4 ныряет на запад под левую шапку)
  en = add_entity_cell(list, en, ug_belt, c_h_ug_L, 4, 1, 1, dir_w, { type = "input" }, offset_x, offset_y)
  -- Лента y=4 от центрального сплиттера ингр.3+4 (выходит из его выхода на y=4 — но сплиттер на y=3!
  -- Значит на y=4 — обычная лента ←
  for x = c_h_ug_L + 1, c_split_R_L do
    en = add_entity_cell(list, en, belt_in, x, 4, 1, 1, dir_w, nil, offset_x, offset_y)
  end
  -- А справа от сплиттера ингр.3+4 лента → доходит до правого края
  for x = c_split_R_L + 1, c_inner_R - 1 do
    en = add_entity_cell(list, en, belt_in, x, 4, 1, 1, dir_e, nil, offset_x, offset_y)
  end
  en = add_entity_cell(list, en, belt_in, c_inner_R, 4, 1, 1, dir_e, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, width - 1, 4, 1, 1, dir_s, nil, offset_x, offset_y)

  -- ═══ y=5: нижний сплиттер ИНГР.3+4 + подземки-выходы (продолжение боковых лент) ═══
  en = add_entity_cell(list, en, belt_in, 0, 5, 1, 1, dir_s, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_inner_L, 5, 1, 1, dir_s, { type = "output" }, offset_x, offset_y)
  -- Нижний сплиттер ингр.3+4 (направление север)
  en = add_entity_cell(list, en, splitter, c_split_R_L, 5, 2, 1, dir_n, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_in_3, 5, 1, 1, dir_s, { type = "output" }, offset_x, offset_y)
  en = add_entity_cell(list, en, ug_belt, c_inner_R, 5, 1, 1, dir_s, { type = "output" }, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, width - 1, 5, 1, 1, dir_s, nil, offset_x, offset_y)

  -- ═══ Заворот ингр.4 от подземки к нижнему сплиттеру ═══
  -- Используем столбцы относительно c_split_R_L (правого сплиттера),
  -- чтобы координаты масштабировались для любого W машины.
  -- Для W=3: c_split_R_L=6 → ставим в (7, y=6) ↑ и (8, y=6) ←.
  -- Для W=2: c_split_R_L=5 → (6,6) ↑ и (7,6) ← — между машинами (2..3 и 8..9).
  -- Для W=5: c_split_R_L=8 → (9,6) ↑ и (10,6) ← — между машинами (3..7 и 11..15).
  en = add_entity_cell(list, en, belt_in, c_split_R_L + 2, 6, 1, 1, dir_w, nil, offset_x, offset_y)
  en = add_entity_cell(list, en, belt_in, c_split_R_L + 1, 6, 1, 1, dir_n, nil, offset_x, offset_y)

  return en
end


local function build_body(recipe_node, machine_count, width, W, H,
                          belt_in, belt_out, ins_in, ins_out,
                          recipe_name, mach_name, ing_count, prod_count, body_y, offset_x, offset_y, en, list, has_fluid, beacon_bay)
  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  local ug_belt = to_underground(belt_in)
  if not entity_exists(ug_belt) then ug_belt = "underground-belt" end

  -- Колонки. Для 1-2 ингр.: ширина 2*W+7, машины смещены к краям.
  -- Для 3-4 ингр.: ширина 2*W+9, добавлены внутренние ленты (столбцы 1 и width-2).
  --
  -- 1-2 ингр. (width=13 для W=3):
  --   c_belt_L=0, c_ins_in_L=1, c_mach_L=2..4, c_ins_out_L=5,
  --   c_belt_C=6, c_ins_out_R=7, c_mach_R=8..10, c_ins_in_R=11, c_belt_R=12
  --
  -- 3-4 ингр. (width=15 для W=3):
  --   c_belt_L=0, c_inner_L=1, c_ins_in_L=2, c_mach_L=3..5, c_ins_out_L=6,
  --   c_belt_C=7, c_ins_out_R=8, c_mach_R=9..11, c_ins_in_R=12, c_inner_R=13, c_belt_R=14
  local c_belt_L, c_inner_L, c_ins_in_L, c_mach_L, c_ins_out_L, c_belt_C
  local c_ins_out_R, c_mach_R, c_ins_in_R, c_inner_R, c_belt_R

  if ing_count >= 3 then
    c_belt_L    = 0
    c_inner_L   = 1
    c_ins_in_L  = 2
    c_mach_L    = 3
    c_ins_out_L = c_mach_L + W           -- = 6 для W=3
    -- Правую сторону считаем СПРАВА — иначе при W≠3 машины не совпадают со шапкой.
    -- Шапка для 3-4 ингр. ставит правый сплиттер в (c_mach_R - 3, ...), а машина
    -- предполагается прижатой к c_inner_R - 1 = width - 3.
    c_belt_R    = width - 1
    c_inner_R   = c_belt_R - 1           -- = width - 2
    c_ins_in_R  = c_inner_R - 1          -- = width - 3
    c_mach_R    = c_ins_in_R - W         -- = width - 3 - W
    c_ins_out_R = c_mach_R - 1           -- = width - 4 - W
    -- Центральная лента продукта — между правым и левым выходом
    c_belt_C    = math.floor((c_ins_out_L + c_ins_out_R) / 2)
    if c_belt_C == c_ins_out_L or c_belt_C == c_ins_out_R then
      c_belt_C = c_ins_out_L + 1
    end
  else
    c_belt_L    = 0
    c_inner_L   = nil
    c_ins_in_L  = 1
    c_mach_L    = 2
    c_ins_out_L = c_mach_L + W           -- = 5
    c_belt_C    = c_ins_out_L + 1        -- = 6
    c_ins_out_R = c_belt_C + 1           -- = 7
    c_mach_R    = width - 2 - W          -- = 8 для width=13, W=3
    c_ins_in_R  = width - 2              -- = 11
    c_inner_R   = nil
    c_belt_R    = width - 1              -- = 12
  end

  local pairs_count = math.ceil(machine_count / 2)
  local output_rate=0
  for _,item in ipairs(recipe_node.products or {}) do
    if item.type~="fluid" then output_rate=output_rate+get_flow_per_sec(item,recipe_node) end
  end
  -- An unequal pair of machine banks can overload one output lane while the
  -- other remains free. Additional bottom outputs side-load the opposite lane.
  local balanced_outputs=ing_count<=2 and not has_fluid and prod_count==1
    and output_rate*math.ceil(machine_count/2)/machine_count>belt_throughput(belt_out)/2+1e-8
  local row_stride=H
  local body_height = pairs_count * row_stride+(balanced_outputs and 3 or 0)

  local mach_extra
  if recipe_name and prototypes.recipe[recipe_name] then
    mach_extra = { recipe = recipe_name }
  end

  -- Машины и манипуляторы
  local first_in_y    = nil  -- Y первого манипулятора входа (любого, для зачина)
  local last_in_y_L   = nil  -- Y последнего манипулятора входа ЛЕВОЙ машины
  local last_in_y_R   = nil  -- Y последнего манипулятора входа ПРАВОЙ машины
  local last_mach_y_L = nil  -- Y нижней клетки последней ЛЕВОЙ машины
  local last_mach_y_R = nil  -- Y нижней клетки последней ПРАВОЙ машины
  local first_out_y   = nil
  local last_out_y    = nil

  -- Transfer planning below handles all additional loading and unloading devices.
  local input_arms=1
  local function add_input_arms(column,row_top,default_y,direction,left_side)
    local rows={default_y};local used={[default_y]=true}
    -- Start with the far end of the same machine face, then fill spare rows.
    local candidates={row_top,row_top+H-1}
    for row=row_top,row_top+H-1 do candidates[#candidates+1]=row end
    for _,y in ipairs(candidates) do
      if #rows>=input_arms then break end
      if not used[y] and not (has_fluid and y==row_top+math.floor(H/2)) then
        rows[#rows+1]=y;used[y]=true
      end
    end
    for _,y in ipairs(rows) do
      en=add_entity_cell(list,en,ins_in,column,y,1,1,direction,nil,offset_x,offset_y)
      first_in_y=math.min(first_in_y or y,y)
      if left_side then last_in_y_L=math.max(last_in_y_L or y,y)
      else last_in_y_R=math.max(last_in_y_R or y,y) end
    end
    if #rows<input_arms then warn_capacity(recipe_name,"not enough room for input inserters") end
  end

  for pair_i = 0, pairs_count - 1 do
    local row_top = body_y + pair_i * row_stride

    -- Левая машина
    if pair_i * 2 + 1 <= machine_count then
      local mach_dir = dir_n
      if has_fluid then mach_dir = dir_w end  -- жидкий вход слева
      en = add_entity_cell(list, en, mach_name, c_mach_L, row_top, W, H, mach_dir,
        mach_extra, offset_x, offset_y)
      local mach_bot_L = row_top + H - 1
      if last_mach_y_L == nil or mach_bot_L > last_mach_y_L then last_mach_y_L = mach_bot_L end

      if ing_count >= 3 then
        local ins_y_top = row_top
        local ins_y_bot = row_top + H - 1
        en = add_entity_cell(list, en, ins_in, c_ins_in_L, ins_y_top, 1, 1, dir_w, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, ins_in, c_ins_in_L, ins_y_bot, 1, 1, dir_w, nil, offset_x, offset_y)

        local ins_out_y = (pair_i % 2 == 0) and ins_y_bot or ins_y_top
        if prod_count >= 1 then
          en = add_entity_cell(list, en, ins_out, c_ins_out_L, ins_out_y, 1, 1, dir_w, nil, offset_x, offset_y)
        end

        if first_in_y    == nil or ins_y_top  < first_in_y    then first_in_y    = ins_y_top end
        if last_in_y_L   == nil or ins_y_bot  > last_in_y_L   then last_in_y_L   = ins_y_bot end
        if prod_count >= 1 then
          if first_out_y   == nil or ins_out_y  < first_out_y   then first_out_y   = ins_out_y end
          if last_out_y    == nil or ins_out_y  > last_out_y    then last_out_y    = ins_out_y end
        end
      else
        -- Манипулятор-вход и боковая лента нужны только если есть ТВЁРДЫЕ ингредиенты.
        -- Манипулятор-выход и центральная лента — только если есть ТВЁРДЫЕ продукты.
        --
        -- Манипулятор-вход:
        --   для химзавод-подобной машины (точки соединения трубы на y_off=±1) ставим
        --   манипулятор в ЦЕНТРЕ грани (y_off=0), чтобы не мешать жидкости.
        --   для обычной машины — на y_off=±1, чередуясь по pair_i.
        local ins_in_y, ins_out_y
        if ing_count >= 1 then
          if is_chemplant_like(mach_name) then
            ins_in_y = row_top + math.floor(H / 2)
          else
            ins_in_y = (pair_i % 2 == 0) and (row_top + H - 1) or row_top
          end
        end
        if prod_count >= 1 then
          ins_out_y = (pair_i % 2 == 0) and (row_top + H - 1) or row_top
        end

        if ing_count >= 1 then
          add_input_arms(c_ins_in_L,row_top,ins_in_y,dir_w,true)
        end
        if prod_count >= 1 then
          en = add_entity_cell(list, en, ins_out, c_ins_out_L, ins_out_y, 1, 1, dir_w, nil, offset_x, offset_y)
        end

        if ins_in_y then
          if first_in_y    == nil or ins_in_y  < first_in_y    then first_in_y    = ins_in_y  end
          if last_in_y_L   == nil or ins_in_y  > last_in_y_L   then last_in_y_L   = ins_in_y  end
        end
        if ins_out_y then
          if first_out_y   == nil or ins_out_y < first_out_y   then first_out_y   = ins_out_y end
          if last_out_y    == nil or ins_out_y > last_out_y    then last_out_y    = ins_out_y end
        end
      end
    end

    -- Правая машина
    if pair_i * 2 + 2 <= machine_count then
      local mach_dir = dir_n
      if has_fluid then mach_dir = dir_e end  -- жидкий вход справа
      en = add_entity_cell(list, en, mach_name, c_mach_R, row_top, W, H, mach_dir,
        mach_extra, offset_x, offset_y)
      local mach_bot_R = row_top + H - 1
      if last_mach_y_R == nil or mach_bot_R > last_mach_y_R then last_mach_y_R = mach_bot_R end

      if ing_count >= 3 then
        local ins_y_top = row_top
        local ins_y_bot = row_top + H - 1
        en = add_entity_cell(list, en, ins_in, c_ins_in_R, ins_y_top, 1, 1, dir_e, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, ins_in, c_ins_in_R, ins_y_bot, 1, 1, dir_e, nil, offset_x, offset_y)

        local ins_out_y = (pair_i % 2 == 0) and ins_y_bot or ins_y_top
        if prod_count >= 1 then
          en = add_entity_cell(list, en, ins_out, c_ins_out_R, ins_out_y, 1, 1, dir_e, nil, offset_x, offset_y)
        end

        if last_in_y_R == nil or ins_y_bot > last_in_y_R then last_in_y_R = ins_y_bot end
      else
        local ins_in_y, ins_out_y
        if ing_count >= 1 then
          if is_chemplant_like(mach_name) then
            ins_in_y = row_top + math.floor(H / 2)
          else
            ins_in_y = (pair_i % 2 == 0) and (row_top + H - 1) or row_top
          end
        end
        if prod_count >= 1 then
          ins_out_y = (pair_i % 2 == 0) and (row_top + H - 1) or row_top
        end
        if ing_count >= 1 then
          add_input_arms(c_ins_in_R,row_top,ins_in_y,dir_e,false)
        end
        if prod_count >= 1 then
          en = add_entity_cell(list, en, ins_out, c_ins_out_R, ins_out_y, 1, 1, dir_e, nil, offset_x, offset_y)
        end
        if ins_in_y then
          if last_in_y_R == nil or ins_in_y > last_in_y_R then last_in_y_R = ins_in_y end
        end
      end
    end
    if balanced_outputs and pair_i==pairs_count-1 then
      local y=row_top+H
      local function bottom_output(machine_x,left_side)
        local x=machine_x+math.floor(W/2)
        en=add_entity_cell(list,en,ins_out,x,y,1,1,dir_n,nil,offset_x,offset_y)
        if left_side then
          for bx=x,c_belt_C-1 do en=add_entity_cell(list,en,belt_out,bx,y+1,1,1,dir_e,nil,offset_x,offset_y) end
        else
          for bx=c_belt_C+1,x do en=add_entity_cell(list,en,belt_out,bx,y+1,1,1,dir_w,nil,offset_x,offset_y) end
        end
      end
      if pair_i*2+1<=machine_count then bottom_output(c_mach_L,true) end
      if pair_i*2+2<=machine_count then bottom_output(c_mach_R,false) end
    end
  end

  -- Центральный конвейер продукта (юг):
  -- начинается с первого манипулятора выхода, заканчивается на нижней клетке блока
  -- (= последний ряд последней пары машин, где ещё стоит здание).
  if beacon_bay and first_out_y then
    local merge_y = body_y + body_height
    local left, right = c_ins_out_L + 1, c_ins_out_R - 1
    local function collector(x, step, direction)
      for y = first_out_y, merge_y - 1 do
        en = add_entity_cell(list, en, belt_out, x, y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
      for column = x, c_belt_C - step, step do
        en = add_entity_cell(list, en, belt_out, column, merge_y, 1, 1, direction, nil, offset_x, offset_y)
      end
    end
    collector(left, 1, dir_e)
    collector(right, -1, dir_w)
    for y = merge_y, merge_y + 1 do
      en = add_entity_cell(list, en, belt_out, c_belt_C, y, 1, 1, dir_s, nil, offset_x, offset_y)
    end
    body_height = body_height + 2
  elseif first_out_y then
    local belt_end_y = body_y + body_height - 1
    for y = first_out_y, belt_end_y do
      en = add_entity_cell(list, en, belt_out, c_belt_C, y, 1, 1, dir_s, nil, offset_x, offset_y)
    end
  end

  -- Внутренние и внешние ленты для 3-4 ингр. (столбцы 0, 1, 13, 14)
  -- Согласно эталону:
  --
  --   Столбец 0 (внешняя): СИНЯЯ лента (ингр.1+2) идёт ↓
  --     На стыках "U-петля" (1-й, 3-й, 5-й...) лента поворачивает → в столбец 1,
  --     там 1 клетка ↓, потом ← обратно в столбец 0 и ↓ дальше.
  --
  --   Столбец 1 (внутренняя): КРАСНАЯ лента (ингр.3+4) идёт ↓
  --     Внутри каждой пары машин — под землёй (input на верхнем ряду пары,
  --     output на нижнем ряду пары).
  --     На стыках "подземка" (2-й, 4-й...) — между парами тоже подземка
  --     (output вверху стыка, input внизу).
  --     На стыках "U-петля" — на этих 2 клетках столбец 1 занят синей U-петлёй,
  --     а красная под землёй (длинная подземка через 2 пары).
  --
  -- Стыки между парами чередуются: 0=U-петля, 1=подземка, 2=U-петля, ...
  --
  if ing_count >= 3 and c_inner_L then
    -- Считаем какие пары имеют ЛЕВУЮ и ПРАВУЮ машины.
    -- Если общее число машин нечётное, последняя пара содержит только левую.
    -- Тогда правая боковая лента / подземка / стыки должны заканчиваться раньше.
    local last_pair_L = -1   -- индекс последней пары с левой машиной
    local last_pair_R = -1   -- индекс последней пары с правой машиной
    for pair_i = 0, pairs_count - 1 do
      if pair_i * 2 + 1 <= machine_count then last_pair_L = pair_i end
      if pair_i * 2 + 2 <= machine_count then last_pair_R = pair_i end
    end

    -- Keep the transport loop complete for an odd last machine. Truncating
    -- the opposite bank used to leave the inner resource tunnel without an exit.
    local close_odd_bank=machine_count>1 and machine_count%2==1
    if close_odd_bank then last_pair_R=last_pair_L end
    -- Y-границы для левой и правой колонн
    local body_end_L = (last_pair_L >= 0) and (body_y + (last_pair_L + 1) * H - 1) or (body_y - 1)
    local body_end_R = (last_pair_R >= 0) and (body_y + (last_pair_R + 1) * H - 1) or (body_y - 1)

    -- Y-петель для левой стороны (стык между парами joint_i и joint_i+1, обе должны иметь левую машину)
    -- На правой стороне — то же, но обе пары должны иметь правую машину.
    local u_loop_y_tops_L = {}
    local u_loop_y_tops_R = {}
    local last_u_loop_y_bot_L = nil
    local last_u_loop_y_bot_R = nil
    for joint_i = 0, pairs_count - 2 do
      if joint_i % 2 == 0 then
        local y_top = body_y + (joint_i + 1) * H - 1
        -- Стык joint_i — между парой joint_i и парой joint_i+1
        if joint_i + 1 <= last_pair_L then
          u_loop_y_tops_L[y_top] = true
          last_u_loop_y_bot_L = y_top + 1
        end
        if joint_i + 1 <= last_pair_R then
          u_loop_y_tops_R[y_top] = true
          last_u_loop_y_bot_R = y_top + 1
        end
      end
    end

    -- ── Внешние СИНИЕ ленты в столбцах 0 и width-1 ──
    -- Левая лента идёт от body_y до body_end_L (низ последней ЛЕВОЙ машины), пропуская
    -- клетки U-петель и клетку body_end_L если для последней одиночной L-пары будет
    -- ставиться "хвостовая" U-петля (стрелка `>` вместо `v`).
    local last_L_solo_pre = (function()
      local lL, lR = -1, -1
      for pi = 0, pairs_count - 1 do
        if pi * 2 + 1 <= machine_count then lL = pi end
        if pi * 2 + 2 <= machine_count then lR = pi end
      end
      return lL > lR
    end)()
    if close_odd_bank then last_L_solo_pre=false end
    local last_R_solo_pre = false  -- в нашей геометрии right_solo не бывает
    -- Для 1-парного блока (без стыков) на body_end_L/R надо ставить поворот (стрелку)
    -- к центру для замыкания U-петли, поэтому пропускаем эту клетку в обычном цикле.
    local single_pair = pairs_count == 1
    local terminal_pair = H==3 and pairs_count>1 and pairs_count%2==1
    -- Когда у блока есть одиночная L-пара (last_L_solo=true), правая внешняя лента
    -- c_belt_R "обрезается" на y_top последнего стыка R, т.к. ниже неё нет R-машин,
    -- которым она могла бы подавать поток через U-петлю.
    local belt_R_max_y = body_end_R
    if last_L_solo_pre and not single_pair then
      -- Последний стык, где has_R = true — это joint_i с y_top на пограничье L+R пар.
      -- has_R = (joint_i + 1) <= last_pair_R. Последний joint_i_R = last_pair_R - 1.
      -- y_top = body_y + (joint_i + 1) * H - 1 = body_y + last_pair_R * H - 1
      local last_R_joint_idx = last_pair_R - 1
      if last_R_joint_idx >= 0 then
        local last_R_joint_y_top = body_y + (last_R_joint_idx + 1) * H - 1
        belt_R_max_y = last_R_joint_y_top
      end
    end
    for y = body_y, body_end_L do
      local skip_for_solo  = last_L_solo_pre and y == body_end_L
      local skip_for_uloop = (single_pair or terminal_pair) and y == body_end_L
      if not u_loop_y_tops_L[y] and not skip_for_solo and not skip_for_uloop then
        en = add_entity_cell(list, en, belt_in, c_belt_L, y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
    end
    for y = body_y, belt_R_max_y do
      local skip_for_solo  = last_R_solo_pre and y == body_end_R
      local skip_for_uloop = (single_pair or terminal_pair) and y == body_end_R
      if not u_loop_y_tops_R[y] and not skip_for_solo and not skip_for_uloop then
        en = add_entity_cell(list, en, belt_in, c_belt_R, y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
    end

    -- ── Стыки между парами (раздельно для L и R) ──
    -- Чётные стыки (0, 2, ...) — U-петля СИНЕЙ ленты.
    -- Нечётные стыки (1, 3, ...) — подземка КРАСНОЙ ленты.
    -- Стык joint_i ставится на сторону X только если на обеих смежных парах есть машина X.
    for joint_i = 0, pairs_count - 2 do
      local y_top = body_y + (joint_i + 1) * H - 1
      local y_bot = y_top + 1
      local is_u_loop = (joint_i % 2 == 0)
      local has_L = (joint_i + 1 <= last_pair_L)
      local has_R = (joint_i + 1 <= last_pair_R)

      if is_u_loop then
        if has_L then
          en = add_entity_cell(list, en, belt_in, c_belt_L, y_top, 1, 1, dir_e, nil, offset_x, offset_y)
          en = add_entity_cell(list, en, belt_in, c_inner_L, y_top, 1, 1, dir_s, nil, offset_x, offset_y)
          en = add_entity_cell(list, en, belt_in, c_inner_L, y_bot, 1, 1, dir_w, nil, offset_x, offset_y)
        end
        if has_R then
          en = add_entity_cell(list, en, belt_in, c_belt_R, y_top, 1, 1, dir_w, nil, offset_x, offset_y)
          en = add_entity_cell(list, en, belt_in, c_inner_R, y_top, 1, 1, dir_s, nil, offset_x, offset_y)
          en = add_entity_cell(list, en, belt_in, c_inner_R, y_bot, 1, 1, dir_e, nil, offset_x, offset_y)
        end
      else
        if has_L then
          en = add_entity_cell(list, en, ug_belt, c_inner_L, y_top, 1, 1, dir_s,
            { type = "output" }, offset_x, offset_y)
          if terminal_pair and joint_i==pairs_count-2 then
            -- Keep the last machine's top pickup on the inner feed. Its
            -- tunnel crosses under the independent outer-feed end below.
            en=add_entity_cell(list,en,belt_in,c_inner_L,y_bot,1,1,dir_s,nil,offset_x,offset_y)
            en=add_entity_cell(list,en,ug_belt,c_inner_L,y_bot+1,1,1,dir_s,{type="input"},offset_x,offset_y)
          else
          en = add_entity_cell(list, en, ug_belt, c_inner_L, y_bot, 1, 1, dir_s,
            { type = "input" }, offset_x, offset_y)
          end
        end
        if has_R then
          en = add_entity_cell(list, en, ug_belt, c_inner_R, y_top, 1, 1, dir_s,
            { type = "output" }, offset_x, offset_y)
          if terminal_pair and joint_i==pairs_count-2 then
            -- Keep the last machine's top pickup on the inner feed. Its
            -- tunnel crosses under the independent outer-feed end below.
            en=add_entity_cell(list,en,belt_in,c_inner_R,y_bot,1,1,dir_s,nil,offset_x,offset_y)
            en=add_entity_cell(list,en,ug_belt,c_inner_R,y_bot+1,1,1,dir_s,{type="input"},offset_x,offset_y)
          else
          en = add_entity_cell(list, en, ug_belt, c_inner_R, y_bot, 1, 1, dir_s,
            { type = "input" }, offset_x, offset_y)
          end
        end
      end
    end

    -- ── Краевые подземки красной ленты ──
    -- Вход — на верхнем ряду первой пары.
    -- Выход — на нижнем ряду последней пары, у которой есть машина с этой стороны.
    -- ИСКЛЮЧЕНИЕ: если last_pair_L одиночный (только левая машина в нём, без правой),
    -- то на левой стороне краевая Uo не ставится. Вместо этого делается U-петля
    -- "снизу" блока: внешняя лента поворачивает вправо, внутренняя продолжается вниз.
    -- Это нужно, чтобы внутренняя лента (ресурсы 3-4) реально добегала до манипулятора
    -- последней машины, а не обрывалась подземкой.
    -- ЕЩЁ: если всего ОДНА пара (pairs_count == 1), нет стыков, и подземки на инпуте/аутпуте
    -- не нужны — ставим обычные ленты для соединения с шапкой / уходом снизу.
    local last_L_solo = (last_pair_L > last_pair_R)
    local last_R_solo = (last_pair_R > last_pair_L)  -- не должно случаться в нашей геометрии
    local has_joints = pairs_count >= 2

    if last_pair_L >= 0 then
      if has_joints then
        en = add_entity_cell(list, en, ug_belt, c_inner_L, body_y, 1, 1, dir_s,
          { type = "input" }, offset_x, offset_y)
      else
        -- Одна пара: вместо подземки на body_y ставим обычную ленту вниз
        en = add_entity_cell(list, en, belt_in, c_inner_L, body_y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
      if terminal_pair then
        en=add_entity_cell(list,en,belt_in,c_belt_L,body_end_L,1,1,dir_e,nil,offset_x,offset_y)
        en=add_entity_cell(list,en,belt_in,c_inner_L,body_end_L,1,1,dir_e,nil,offset_x,offset_y)
        en=add_entity_cell(list,en,ug_belt,c_inner_L,body_end_L+1,1,1,dir_s,{type="output"},offset_x,offset_y)
      elseif last_L_solo then
        en = add_entity_cell(list, en, belt_in, c_belt_L, body_end_L, 1, 1, dir_e, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, belt_in, c_inner_L, body_end_L, 1, 1, dir_s, nil, offset_x, offset_y)
      elseif has_joints then
        en = add_entity_cell(list, en, ug_belt, c_inner_L, body_end_L, 1, 1, dir_s,
          { type = "output" }, offset_x, offset_y)
      else
        -- Одна пара (не solo): U-петля внизу — внешняя лента поворачивает вправо `>`,
        -- внутренняя продолжает вниз `v`. Это обеспечивает поток без подземок.
        en = add_entity_cell(list, en, belt_in, c_belt_L, body_end_L, 1, 1, dir_e, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, belt_in, c_inner_L, body_end_L, 1, 1, dir_s, nil, offset_x, offset_y)
      end
    end
    if last_pair_R >= 0 then
      if has_joints then
        en = add_entity_cell(list, en, ug_belt, c_inner_R, body_y, 1, 1, dir_s,
          { type = "input" }, offset_x, offset_y)
      else
        en = add_entity_cell(list, en, belt_in, c_inner_R, body_y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
      if terminal_pair then
        en=add_entity_cell(list,en,belt_in,c_belt_R,body_end_R,1,1,dir_w,nil,offset_x,offset_y)
        en=add_entity_cell(list,en,belt_in,c_inner_R,body_end_R,1,1,dir_w,nil,offset_x,offset_y)
        en=add_entity_cell(list,en,ug_belt,c_inner_R,body_end_R+1,1,1,dir_s,{type="output"},offset_x,offset_y)
      elseif last_R_solo then
        en = add_entity_cell(list, en, belt_in, c_belt_R, body_end_R, 1, 1, dir_w, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, belt_in, c_inner_R, body_end_R, 1, 1, dir_s, nil, offset_x, offset_y)
      elseif has_joints then
        en = add_entity_cell(list, en, ug_belt, c_inner_R, body_end_R, 1, 1, dir_s,
          { type = "output" }, offset_x, offset_y)
      else
        -- Одна пара: U-петля справа — поворот влево `<` + внутренняя `v`
        en = add_entity_cell(list, en, belt_in, c_belt_R, body_end_R, 1, 1, dir_w, nil, offset_x, offset_y)
        en = add_entity_cell(list, en, belt_in, c_inner_R, body_end_R, 1, 1, dir_s, nil, offset_x, offset_y)
      end
    end
  else
    -- Для 1-2 ингр. — обычные боковые ленты, левая и правая отдельно.
    -- Если в рецепте 0 твёрдых ингредиентов (только жидкие) — боковые ленты
    -- НЕ нужны, их нечем заполнять.
    -- Лента обрывается на манипуляторе (last_in_y): дальше она не нужна.
    if ing_count >= 1 then
      local side_belt_end_L = last_in_y_L or (body_y + body_height - 1)
      local side_belt_end_R = last_in_y_R or (body_y + body_height - 1)
      for y = body_y, side_belt_end_L do
        en = add_entity_cell(list, en, belt_in, c_belt_L, y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
      for y = body_y, side_belt_end_R do
        en = add_entity_cell(list, en, belt_in, c_belt_R, y, 1, 1, dir_s, nil, offset_x, offset_y)
      end
    end
  end

  return en, body_height
end

-- ── Генерация блока для нефтезавода (oil-refinery) ──────────────
-- Топология: машины 5×5 ставятся вертикальным столбом dir=east, без зазоров.
-- Слева: 0..n_in стояков для жидких ВХОДОВ (max 2).
--   Привязка по индексу ингредиента:
--     ingredients[1] → y_off=+1 → ближний стояк (X = mach_left_x - 2), отвод прямой pipe в (X-1)
--     ingredients[2] → y_off=-1 → дальний стояк (X = mach_left_x - 4),
--                     отвод парой ptog (X-3 west) + (X-1 east)
-- Справа: 0..n_out стояков для жидких ВЫХОДОВ (max 3).
--   Привязка по индексу продукта:
--     products[1] → y_off=-2 → средний стояк (X = mach_right_x + 3),
--                  отвод парой ptog (X+0 west) + (X+2 east)
--     products[2] → y_off= 0 → ближний стояк (X = mach_right_x + 1),
--                  отвод прямой pipe в (X+0)
--     products[3] → y_off=+2 → дальний стояк (X = mach_right_x + 5),
--                  отвод парой ptog (X+0 west) + (X+4 east)
-- Возвращает: en, total_height
local function build_block_refinery(recipe_node, offset_x, offset_y, settings, en, list, cache, meta_out)
  local pipe_main_name = settings.pipe or "pipe"
  local pipe_ug_name = to_pipe_underground(pipe_main_name)
  local mach_name = "oil-refinery"
  local W, H      = 5, 5
  local count     = get_machine_count(recipe_node)
  local f_ing     = get_fluid_ingredients(recipe_node)
  local f_prod    = get_fluid_products(recipe_node)
  local n_in      = #f_ing
  local n_out     = #f_prod

  -- Проверка: refinery поддерживает максимум 2 входа и 3 выхода
  if n_in > 2 or n_out > 3 then
    if game and game.print then
      game.print({"", "[blueprint-from-helmod] ",
        "Рецепт '", recipe_node.name or "?",
        "': в нефтезаводе максимум 2 жидких входа и 3 жидких выхода. ",
        "Похоже, используется модовое здание с расширенным числом входов/выходов. ",
        "Блок не построен."})
    end
    return en, 0, { offset_x = offset_x, offset_y = offset_y, width = 0, height = 0 }
  end

  -- Спецификации стояков (для каждого индекса ингредиента/продукта).
  local left_specs = {
    -- [ingredient_idx] = {dx_stack от mach_left_x (отрицательное), y_off от центра, тип отвода}
    [1] = { dx_stack = -2, y_off =  1, conn = pipe_main_name      },  -- ближний
    [2] = { dx_stack = -4, y_off = -1, conn = "ptog_pair" },  -- дальний
  }
  local right_specs = {
    -- [product_idx] = {dx_stack от mach_right_x, y_off от центра, тип отвода}
    [1] = { dx_stack = 1, y_off =  0, conn = pipe_main_name      },  -- ближний (продукт всегда сюда первый)
    [2] = { dx_stack = 3, y_off = -2, conn = "ptog_mid"  },  -- средний (второй продукт)
    [3] = { dx_stack = 5, y_off =  2, conn = "ptog_far"  },  -- дальний (третий продукт)
  }

  -- ── Вычисляем фактические границы блока ──
  -- Левая часть: ширина = |min(dx_stack) used| для всех использованных слева.
  --   Если используется только [1] (ближний, dx=-2): нужны клетки X-1 и X-2 → 2 клетки.
  --   Если используется [1] и [2] (dx=-4): нужны X-1..X-4 → 4 клетки.
  local left_w = 0
  for i = 1, n_in do
    local need = -left_specs[i].dx_stack  -- 2 или 4
    if need > left_w then left_w = need end
  end
  -- Правая часть: ширина = max(dx_stack) used.
  --   Если используется только [2] (ближний, dx=+1): X+0 и X+1 → 2 клетки.
  --   Если используется [1] (средний, dx=+3): нужны X+0..X+3 → 4 клетки.
  --   Если [3] (дальний, dx=+5): нужны X+0..X+5 → 6 клеток.
  local right_w = 0
  for i = 1, n_out do
    local need = right_specs[i].dx_stack + 1
    if need > right_w then right_w = need end
  end

  local total_w = left_w + W + right_w
  local total_h = count * H

  local mach_left_x  = offset_x + left_w
  local mach_right_x = mach_left_x + W
  local mach_top_y   = offset_y

  -- ── Машины ──
  local mach_extra_r
  if recipe_node.name and prototypes.recipe[recipe_node.name] then
    mach_extra_r = { recipe = recipe_node.name }
  end
  for i = 0, count - 1 do
    en = add_entity_cell(list, en, mach_name, mach_left_x, mach_top_y + i * H, W, H,
      defines.direction.east, mach_extra_r, 0, 0)
  end

  -- ── Левые стояки ──
  for i = 1, n_in do
    local sp = left_specs[i]
    local stack_x = mach_left_x + sp.dx_stack
    -- Сначала собираем y всех клеток соединения для этого стояка, чтобы обрезать pipe
    -- сверху и снизу — стояк нужен только от верхней до нижней подключённой клетки.
    local conn_y_min, conn_y_max = nil, nil
    for mi = 0, count - 1 do
      local m_centre_y = mach_top_y + mi * H + 2
      local face_y     = m_centre_y + sp.y_off
      if conn_y_min == nil or face_y < conn_y_min then conn_y_min = face_y end
      if conn_y_max == nil or face_y > conn_y_max then conn_y_max = face_y end
    end
    -- Сплошной стояк только в пределах подключений
    for y = conn_y_min, conn_y_max do
      en = add_entity_cell(list, en, pipe_main_name, stack_x, y, 1, 1, 0, nil, 0, 0)
    end
    -- Подключения к каждой машине
    for mi = 0, count - 1 do
      local m_centre_y = mach_top_y + mi * H + 2
      local face_y     = m_centre_y + sp.y_off
      if sp.conn == pipe_main_name then
        en = add_entity_cell(list, en, pipe_main_name, mach_left_x - 1, face_y, 1, 1, 0, nil, 0, 0)
      else  -- "ptog_pair" — для дальнего стояка
        en = add_entity_cell(list, en, pipe_ug_name, mach_left_x - 3, face_y, 1, 1,
          defines.direction.west, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_ug_name, mach_left_x - 1, face_y, 1, 1,
          defines.direction.east, nil, 0, 0)
      end
    end
  end

  -- ── Правые стояки ──
  for i = 1, n_out do
    local sp = right_specs[i]
    local stack_x = mach_right_x + sp.dx_stack
    local conn_y_min, conn_y_max = nil, nil
    for mi = 0, count - 1 do
      local m_centre_y = mach_top_y + mi * H + 2
      local face_y     = m_centre_y + sp.y_off
      if conn_y_min == nil or face_y < conn_y_min then conn_y_min = face_y end
      if conn_y_max == nil or face_y > conn_y_max then conn_y_max = face_y end
    end
    for y = conn_y_min, conn_y_max do
      en = add_entity_cell(list, en, pipe_main_name, stack_x, y, 1, 1, 0, nil, 0, 0)
    end
    for mi = 0, count - 1 do
      local m_centre_y = mach_top_y + mi * H + 2
      local face_y     = m_centre_y + sp.y_off
      if sp.conn == pipe_main_name then
        en = add_entity_cell(list, en, pipe_main_name, mach_right_x, face_y, 1, 1, 0, nil, 0, 0)
      elseif sp.conn == "ptog_mid" then
        en = add_entity_cell(list, en, pipe_ug_name, mach_right_x, face_y, 1, 1,
          defines.direction.west, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_ug_name, mach_right_x + 2, face_y, 1, 1,
          defines.direction.east, nil, 0, 0)
      else  -- ptog_far
        en = add_entity_cell(list, en, pipe_ug_name, mach_right_x, face_y, 1, 1,
          defines.direction.west, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_ug_name, mach_right_x + 4, face_y, 1, 1,
          defines.direction.east, nil, 0, 0)
      end
    end
  end

  -- ── meta для соединения блоков (опционально) ──
  if meta_out then
    meta_out.is_refinery_block = true
    meta_out.fluid_inputs  = {}
    meta_out.fluid_outputs = {}
    for i = 1, n_in do
      local sp = left_specs[i]
      meta_out.fluid_inputs[i] = {
        x = mach_left_x + sp.dx_stack, y_top = mach_top_y, y_bot = mach_top_y + total_h - 1,
        ingredient = f_ing[i],
      }
    end
    for i = 1, n_out do
      local sp = right_specs[i]
      meta_out.fluid_outputs[i] = {
        x = mach_right_x + sp.dx_stack, y_top = mach_top_y, y_bot = mach_top_y + total_h - 1,
        product = f_prod[i],
      }
    end
  end

  -- Метаданные блока (для построения подблоков по ширине и связи лент)
  local meta = {
    offset_x   = offset_x,
    offset_y   = offset_y,
    width      = total_w,
    height     = total_h,
    is_refinery_block = true,
    fluid_inputs  = meta_out and meta_out.fluid_inputs  or {},
    fluid_outputs = meta_out and meta_out.fluid_outputs or {},
    ingredients = {},
    products   = {},
    inputs     = {},
    product_out = nil,
  }

  return en, total_h, meta
end


-- ── Генерация блока для chemical-plant с ЧИСТО-ЖИДКОСТНЫМ рецептом ──
-- Топология: пары машин L+R (3×3, dir=west/east), вертикально, без зазоров.
-- Слева — 1 стояк pipe (внешний) для 1 ингр. ИЛИ 2 стояка (внешний + внутренний) для 2 ингр.
-- Справа — симметрично, для жидкого продукта.
-- Подземки/прямые pipe на y_off=±1 от центра каждой машины (это точки соединения труб
-- у chemplant). Для 1 ингредиента подключается только нижняя точка (y_off=+1), пара ptog
-- через внутреннюю клетку. Для 2 ингр. подключаются обе точки разными стояками.
local function build_block_chem_fluid(recipe_node, offset_x, offset_y, settings, en, list, cache)
  local pipe_main_name = settings.pipe or "pipe"
  local pipe_ug_name = to_pipe_underground(pipe_main_name)
  local mach_name = "chemical-plant"
  local W, H      = 3, 3
  local count     = get_machine_count(recipe_node)
  local f_ing     = get_fluid_ingredients(recipe_node)
  local f_prod    = get_fluid_products(recipe_node)
  local n_in      = #f_ing
  local n_out     = #f_prod

  if settings.link_mode ~= "independent" then
    -- Keep a common orientation and abut machines on their unported sides.
    -- The fluid planner then has access to both sides of every machine.
    local recipe = {recipe = recipe_node.name}
    for i = 0, count - 1 do
      en = add_entity_cell(list, en, mach_name, offset_x, offset_y + i * H,
        W, H, defines.direction.west, recipe, 0, 0)
    end
    return en, count * H, {
      offset_x = offset_x, offset_y = offset_y, width = W, height = count * H,
      is_chem_fluid_block = true,
      fluid_inputs = {}, fluid_outputs = {}, ingredients = {}, products = {}, inputs = {},
    }
  end

  if n_in > 2 or n_out > 2 then
    if game and game.print then
      game.print({"", "[blueprint-from-helmod] ",
        "Рецепт '", recipe_node.name or "?",
        "': в химзаводе максимум 2 жидких входа и 2 жидких выхода. Блок не построен."})
    end
    return en, 0, { offset_x=offset_x, offset_y=offset_y, width=0, height=0 }
  end

  -- Геометрия:
  --   n_in = 1: left_w = 2 (внешний стояк, потом 1 клетка подключения = подземка east)
  --             clays: stack(0) . (1=ptog east) | machine_L
  --   n_in = 2: left_w = 4 (внешний стояк, внутренний стояк, 2 клетки подключений)
  --             clays: stack_outer(0) ptog_west(1) stack_inner(2) ptog_east/pipe(3) | machine_L
  local left_w  = (n_in  == 0) and 0 or ((n_in  == 1) and 2 or 4)
  local right_w = (n_out == 0) and 0 or ((n_out == 1) and 2 or 4)
  local total_w = left_w + W + W + right_w   -- 2 машины в паре
  -- count может быть нечётным — последняя пара только left
  local n_pairs = math.ceil(count / 2)
  local total_h = n_pairs * H

  local mach_L_x = offset_x + left_w               -- top-left X левой машины
  local mach_R_x = mach_L_x + W                    -- top-left X правой машины (пристроена вплотную)
  local mach_top_y = offset_y

  -- ── Машины ──
  local mach_extra_cf
  if recipe_node.name and prototypes.recipe[recipe_node.name] then
    mach_extra_cf = { recipe = recipe_node.name }
  end
  for p = 0, n_pairs - 1 do
    local row_top = mach_top_y + p * H
    -- Левая машина
    en = add_entity_cell(list, en, mach_name, mach_L_x, row_top, W, H,
      defines.direction.west, mach_extra_cf, 0, 0)
    -- Правая, только если последняя пара ещё имеет правую машину
    if p * 2 + 2 <= count then
      en = add_entity_cell(list, en, mach_name, mach_R_x, row_top, W, H,
        defines.direction.east, mach_extra_cf, 0, 0)
    end
  end

  -- ── ВХОД (левая сторона) ──
  -- Для каждой машины: y центра = top + 1. Точки соединения = (mach_L_x - 1, y_center ± 1).
  -- При n_in=1: подключаем нижнюю точку (y_off=+1) → ptog пара (внешний стояк → клетка X-1).
  --   external_x = mach_L_x - 2, внутреннее(ptog_W) = mach_L_x - 1
  -- При n_in=2: подключаем обе точки.
  --   external_x = mach_L_x - 4 (внешний стояк, ингр.1)
  --   intermediate_x = mach_L_x - 3 (ptog west под внутренним стояком, для верхней точки)
  --   internal_x = mach_L_x - 2 (внутренний стояк, ингр.2, прямой pipe к нижней точке)
  --   conn_x = mach_L_x - 1 (соединение к грани машины)
  if n_in >= 1 then
    local ext_x = mach_L_x - left_w  -- внешний стояк
    -- Вычисляем диапазон y подключений (для обрезки стояка)
    local conn_y_min, conn_y_max = nil, nil
    for p = 0, n_pairs - 1 do
      local row_top = mach_top_y + p * H
      local centre_y = row_top + 1
      if n_in == 1 then
        local face_y = centre_y + 1
        if conn_y_min == nil or face_y < conn_y_min then conn_y_min = face_y end
        if conn_y_max == nil or face_y > conn_y_max then conn_y_max = face_y end
      else
        local y_top = centre_y - 1
        local y_bot = centre_y + 1
        if conn_y_min == nil or y_top < conn_y_min then conn_y_min = y_top end
        if conn_y_max == nil or y_bot > conn_y_max then conn_y_max = y_bot end
      end
    end
    -- Внешний стояк только в пределах подключений
    for y = conn_y_min, conn_y_max do
      en = add_entity_cell(list, en, pipe_main_name, ext_x, y, 1, 1, 0, nil, 0, 0)
    end
    if n_in == 1 then
      for p = 0, n_pairs - 1 do
        local row_top = mach_top_y + p * H
        local centre_y = row_top + 1
        local face_y = centre_y + 1
        en = add_entity_cell(list, en, pipe_main_name, mach_L_x - 1, face_y, 1, 1, 0, nil, 0, 0)
      end
    else
      local int_x = mach_L_x - 2
      -- Внутренний стояк (тот же диапазон)
      for y = conn_y_min, conn_y_max do
        en = add_entity_cell(list, en, pipe_main_name, int_x, y, 1, 1, 0, nil, 0, 0)
      end
      for p = 0, n_pairs - 1 do
        local row_top = mach_top_y + p * H
        local centre_y = row_top + 1
        local y_top = centre_y - 1
        local y_bot = centre_y + 1
        en = add_entity_cell(list, en, pipe_ug_name, ext_x + 1, y_top, 1, 1,
          defines.direction.west, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_ug_name, ext_x + 3, y_top, 1, 1,
          defines.direction.east, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_main_name, mach_L_x - 1, y_bot, 1, 1, 0, nil, 0, 0)
      end
    end
  end

  -- ── ВЫХОД (правая сторона) ──
  if n_out >= 1 then
    local ext_x = mach_R_x + W + right_w - 1
    -- Подключения только для пар где есть правая машина
    local conn_y_min, conn_y_max = nil, nil
    for p = 0, n_pairs - 1 do
      if p * 2 + 2 <= count then
        local row_top = mach_top_y + p * H
        local centre_y = row_top + 1
        if n_out == 1 then
          local face_y = centre_y + 1
          if conn_y_min == nil or face_y < conn_y_min then conn_y_min = face_y end
          if conn_y_max == nil or face_y > conn_y_max then conn_y_max = face_y end
        else
          local y_top = centre_y - 1
          local y_bot = centre_y + 1
          if conn_y_min == nil or y_top < conn_y_min then conn_y_min = y_top end
          if conn_y_max == nil or y_bot > conn_y_max then conn_y_max = y_bot end
        end
      end
    end
    if conn_y_min then
      for y = conn_y_min, conn_y_max do
        en = add_entity_cell(list, en, pipe_main_name, ext_x, y, 1, 1, 0, nil, 0, 0)
      end
    end
    if n_out == 1 then
      for p = 0, n_pairs - 1 do
        if p * 2 + 2 <= count then
          local row_top = mach_top_y + p * H
          local centre_y = row_top + 1
          local face_y = centre_y + 1  -- нижняя точка (y_off=+1)
          en = add_entity_cell(list, en, pipe_main_name, mach_R_x + W, face_y, 1, 1, 0, nil, 0, 0)
        end
      end
    else
      local int_x = mach_R_x + W + 1
      -- Внутренний стояк только в диапазоне подключений (с conn_y_min/max)
      if conn_y_min then
        for y = conn_y_min, conn_y_max do
          en = add_entity_cell(list, en, pipe_main_name, int_x, y, 1, 1, 0, nil, 0, 0)
        end
      end
      for p = 0, n_pairs - 1 do
        if p * 2 + 2 <= count then
          local row_top = mach_top_y + p * H
          local centre_y = row_top + 1
          local y_top = centre_y - 1
          local y_bot = centre_y + 1
          -- Верхняя output точка → ptog пара (наземно от грани машины (mach_R_x+W) → подземно к ext_x)
          en = add_entity_cell(list, en, pipe_ug_name, mach_R_x + W, y_top, 1, 1,
            defines.direction.west, nil, 0, 0)
          en = add_entity_cell(list, en, pipe_ug_name, mach_R_x + W + 2, y_top, 1, 1,
            defines.direction.east, nil, 0, 0)
          -- Нижняя точка → прямая pipe от грани к внутреннему стояку
          en = add_entity_cell(list, en, pipe_main_name, mach_R_x + W, y_bot, 1, 1, 0, nil, 0, 0)
        end
      end
    end
  end

  local meta = {
    offset_x = offset_x, offset_y = offset_y,
    width = total_w, height = total_h,
    is_chem_fluid_block = true,
    fluid_inputs = {}, fluid_outputs = {},
    ingredients = {}, products = {}, inputs = {}, product_out = nil,
  }
  return en, total_h, meta
end


-- ── Генерация блока для chemical-plant с 1 МАШИНОЙ (без зеркала справа) ──
-- Используется когда машин 1 И есть твёрдые ингредиенты ИЛИ твёрдые продукты
-- (для чисто-жидкостного случая 1 машина используется build_block_chem_fluid).
-- Геометрия слева:
--   2 твёрд. ингр.: left_w=3 — 3 столбца (лента 1, центр. лента, лента 2 с Y-слиянием)
--   1 твёрд. ингр.: left_w=2 — 1 лента + 1 манипулятор
--   0 твёрд., есть жидк.:
--      left_w=3 — пара ptog (P< на 0, P> на 2)
--   0 твёрд. и 0 жидк.: left_w=0
-- Геометрия справа:
--   prod_count >= 1: right_w=2 — манипулятор + 1 клетка ленты
--   жидк. выход: right_w=1 — стояк pipe (3 клетки)
-- Манипулятор-вход для chemplant: центр грани (y_off=0).
-- Подземки жидкости: на y_off=±1 (нижняя точка для 1 жидк., обе для 2 жидк.).
local function build_block_single_chem(recipe_node, offset_x, offset_y, settings, en, list, cache)
  local pipe_main_name = settings.pipe or "pipe"
  local pipe_ug_name = to_pipe_underground(pipe_main_name)
  local mach_name = "chemical-plant"
  local W, H      = 3, 3
  local solid_ing = get_ingredient_names(recipe_node)
  local solid_prod = get_solid_products(recipe_node)
  local f_ing     = get_fluid_ingredients(recipe_node)
  local f_prod    = get_fluid_products(recipe_node)
  local ing_count = #solid_ing
  local prod_count = #solid_prod
  local n_fluid_in = #f_ing
  local n_fluid_out = #f_prod

  -- Поддерживаем только 0-2 твёрд. ингр., 0-1 твёрд. прод., 0-2 жидк. ингр./прод.
  if ing_count > 2 then return nil end
  if prod_count > 1 then return nil end
  if n_fluid_in > 2 or n_fluid_out > 2 then return nil end
  -- Случай "и жидк. и твёрд. выход" — пока не поддерживаем
  if prod_count >= 1 and n_fluid_out >= 1 then return nil end
  -- Случай совсем без входов/выходов — нечего строить
  if ing_count == 0 and n_fluid_in == 0 and prod_count == 0 and n_fluid_out == 0 then return nil end

  local belt_in   = settings.belt_in   or "transport-belt"
  local belt_out  = settings.belt_out  or "transport-belt"
  local ins_in    = settings.inserter_in  or "fast-inserter"
  local ins_out   = settings.inserter_out or "fast-inserter"
  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  -- ── Ширина ──
  local left_w
  if ing_count == 2 then left_w = 3
  elseif ing_count == 1 then left_w = 2
  elseif n_fluid_in >= 1 then left_w = 3
  else left_w = 0 end

  local right_w
  if prod_count >= 1 then right_w = 2
  elseif n_fluid_out >= 1 then right_w = 1
  else right_w = 0 end

  -- ── Высота шапки ──
  local header_h
  if ing_count == 2 then header_h = 3
  else header_h = 0 end

  local total_w = left_w + W + right_w
  local total_h = header_h + H

  local mach_L_x = offset_x + left_w
  local mach_top_y = offset_y + header_h
  local mach_centre_y = mach_top_y + 1

  -- ── Машина ──
  local mach_extra_sc
  if recipe_node.name and prototypes.recipe[recipe_node.name] then
    mach_extra_sc = { recipe = recipe_node.name }
  end
  en = add_entity_cell(list, en, mach_name, mach_L_x, mach_top_y, W, H, dir_w, mach_extra_sc, 0, 0)

  -- ── ШАПКА Y-СЛИЯНИЯ И ЛЕНТА ВХОДА ──
  if ing_count == 2 then
    -- left_w=3: c_belt_1=offset_x+0, c_belt_C=offset_x+1, c_belt_2=offset_x+2
    -- y=0: ленты ↓ на (0) и (2). y=1: > на (0), ↓ на (1), < на (2). y=2: ↓ на (1).
    en = add_entity_cell(list, en, belt_in, offset_x + 0, offset_y + 0, 1, 1, dir_s, nil, 0, 0)
    en = add_entity_cell(list, en, belt_in, offset_x + 2, offset_y + 0, 1, 1, dir_s, nil, 0, 0)
    en = add_entity_cell(list, en, belt_in, offset_x + 0, offset_y + 1, 1, 1, dir_e, nil, 0, 0)
    en = add_entity_cell(list, en, belt_in, offset_x + 1, offset_y + 1, 1, 1, dir_s, nil, 0, 0)
    en = add_entity_cell(list, en, belt_in, offset_x + 2, offset_y + 1, 1, 1, dir_w, nil, 0, 0)
    -- Центральная лента продолжается вниз от y=2 до клетки манипулятора-входа (mach_centre_y).
    -- Манипулятор-вход для chemplant в центре грани = (offset_x + 2, mach_centre_y),
    -- но забирает с (offset_x + 1, mach_centre_y) — это центральная лента.
    -- Лента должна занимать все клетки (offset_x + 1, y) от y=offset_y+2 до y=mach_centre_y включительно.
    for y = offset_y + 2, mach_centre_y do
      en = add_entity_cell(list, en, belt_in, offset_x + 1, y, 1, 1, dir_s, nil, 0, 0)
    end
    en = add_entity_cell(list, en, ins_in, offset_x + 2, mach_centre_y, 1, 1, dir_w, nil, 0, 0)
  elseif ing_count == 1 then
    -- left_w=2: c_belt = offset_x + 0, c_ins = offset_x + 1
    -- Лента: column 0, от верха блока до манипулятора
    -- Манипулятор на (offset_x + 1, mach_centre_y), забирает с (0, ...) кладёт в машину
    for y = mach_top_y, mach_centre_y do
      en = add_entity_cell(list, en, belt_in, offset_x + 0, y, 1, 1, dir_s, nil, 0, 0)
    end
    en = add_entity_cell(list, en, ins_in, offset_x + 1, mach_centre_y, 1, 1, dir_w, nil, 0, 0)
  end

  -- ── ЖИДКИЙ ВХОД (подземки слева, на y_off=±1) ──
  -- Стояк pipe слева НЕ ставим — пользователь подведёт свою жидкость к крайнему столбцу блока.
  -- ptog_west на (offset_x + 0, y_face): наземная west = (offset_x - 1, y_face) — за пределами блока.
  -- ptog_east на (offset_x + 2, y_face): наземная east = (offset_x + 3, y_face) = ? Для left_w=3, это = mach_L_x = ВНУТРИ машины.
  -- Не годится. Перепроверю: точка соединения трубы у машины на west-грани = (mach_L_x - 1, mach_centre_y ± 1).
  -- При left_w=3: mach_L_x - 1 = offset_x + 2. Это И ЕСТЬ клетка соприкосновения.
  -- Поэтому ptog east на (offset_x + 2, y_face) корректен: ptog east сам и есть труба-наземно в (offset_x+2),
  -- соприкасается с гранью машины ((mach_L_x - 1) + 1 = mach_L_x = клетка машины ВНУТРИ; но в Factorio
  -- труба соединяется с fluid_box по ПОЗИЦИИ КЛЕТКИ ТРУБЫ относительно центра машины, и точка соединения = (mach_L_x - 1).
  -- ptog east наземно соединяет себя как трубу с fluid_box).
  -- В случае left_w=2 (ing_count=1): mach_L_x - 1 = offset_x + 1 = c_ins (манипулятор). Конфликт!
  -- В этом случае подземка не помещается под лентой. Нужно ставить под манипулятором — но клетка занята.
  -- Проверю эталон sulfuric-acid: left_w в нём был 3 (ing_count=2), и подземка на (4,17) west + (6,17) east.
  -- Для случая 1 ингр. + жидк. — не уверен какой эталон. Пропустим: при ing_count=1 и n_fluid_in >= 1
  -- расширим left_w до 3 (lent_1 on 0, lent_C/ins on 1, fluid_R on 2). Но это меняет геометрию.
  -- Перепишу: при ing_count == 1 и n_fluid_in >= 1, используем left_w=3 (как при 2 ингр.), но без 2-й ленты.
  if n_fluid_in >= 1 then
    if left_w < 3 then
      -- Случай ing_count=1 + жидк: нужно расширить left_w до 3
      -- Но это уже зафиксированная геометрия. Пропустим и не ставим подземку (с предупреждением).
      if ing_count == 1 and n_fluid_in >= 1 then
        -- TODO: расширить геометрию. Сейчас просто строим без жидк. трубы для этого случая.
        -- Это значит этот специфический комбо ("1 твёрд + 1 жидк, 1 машина") строится некорректно.
      end
    else
      -- Нижняя точка (y_off=+1)
      local y_bot = mach_centre_y + 1
      en = add_entity_cell(list, en, pipe_ug_name, offset_x + 0, y_bot, 1, 1, dir_w, nil, 0, 0)
      en = add_entity_cell(list, en, pipe_ug_name, offset_x + 2, y_bot, 1, 1, dir_e, nil, 0, 0)
      if n_fluid_in >= 2 then
        -- Верхняя точка (y_off=-1)
        local y_top = mach_centre_y - 1
        en = add_entity_cell(list, en, pipe_ug_name, offset_x + 0, y_top, 1, 1, dir_w, nil, 0, 0)
        en = add_entity_cell(list, en, pipe_ug_name, offset_x + 2, y_top, 1, 1, dir_e, nil, 0, 0)
      end
    end
  end

  -- ── ВЫХОД СПРАВА ──
  local mach_R_edge = mach_L_x + W
  if prod_count >= 1 then
    -- Манипулятор-выход + 1 клетка ленты, на y_off=+1 (нижняя точка грани)
    -- Манипулятор dir=west: pickup на west(машина), drop на east(лента)
    -- НО для ВЫХОДА (из машины на ленту) нам нужен ins, чей pickup=машина, drop=лента
    -- inserter dir=west: default pickup (0,-1)→(-1,0)=west=машина (которая на west), drop (0,1)→(1,0)=east=лента ✓
    -- То есть для манипулятора-ВЫХОДА справа от машины (которая dir=west, выход на east-грани) нужен dir=west.
    en = add_entity_cell(list, en, ins_out, mach_R_edge, mach_centre_y + 1, 1, 1, dir_w, nil, 0, 0)
    en = add_entity_cell(list, en, belt_out, mach_R_edge + 1, mach_centre_y + 1, 1, 1, dir_s, nil, 0, 0)
  end
  if n_fluid_out >= 1 then
    -- Стояк pipe справа: 3 клетки (вся east-грань)
    for y = mach_top_y, mach_top_y + H - 1 do
      en = add_entity_cell(list, en, pipe_main_name, mach_R_edge, y, 1, 1, 0, nil, 0, 0)
    end
  end

  local meta = {
    offset_x = offset_x, offset_y = offset_y,
    width = total_w, height = total_h,
    is_single_chem_block = true,
    fluid_inputs = {}, fluid_outputs = {},
    ingredients = solid_ing, products = solid_prod,
    inputs = {}, product_out = nil,
  }
  if ing_count == 1 then
    -- 1 твёрд. ингр.: вход в столбце 0 (лента) на верхней клетке (header_h=0)
    meta.inputs[1] = { x = offset_x + 0, y = mach_top_y, ingredient = solid_ing[1] }
  elseif ing_count == 2 then
    -- 2 твёрд. ингр.: входы на верхней грани блока в столбцах 0 и 2 (шапка y=offset_y)
    meta.inputs[1] = { x = offset_x + 0, y = offset_y, ingredient = solid_ing[1] }
    meta.inputs[2] = { x = offset_x + 2, y = offset_y, ingredient = solid_ing[2] }
  end
  if prod_count >= 1 then
    -- product_out.y в клетке сразу под блоком (BLOCK_GAP конвенция)
    local target_out_y = offset_y + total_h
    local ins_out_y_local = mach_centre_y + 1
    for y = ins_out_y_local + 1, target_out_y - 1 do
      en = add_entity_cell(list, en, belt_out, mach_R_edge + 1, y, 1, 1, dir_s, nil, 0, 0)
    end
    meta.product_out = { x = mach_R_edge + 1, y = target_out_y }
  end
  return en, total_h, meta
end

-- ── Генерация блока для СБОРОЧНОЙ МАШИНЫ с 1 МАШИНОЙ (не chemplant) ──
-- Компактная схема:
--   1 твёрд. ингр.: left_w=2 (лента + манип)
--   2 твёрд. ингр.: left_w=3 (3 столбца, Y-слияние) + 1 манип на верхней клетке грани
--   1 твёрд. прод.: right_w=2 (манип + лента)
-- header_h: 0 для 1 ингр., 3 для 2 ингр. (Y-слияние шапка)
-- Манипулятор-вход на верхней клетке грани (y_off=-1).
-- Манипулятор-выход на нижней клетке грани (y_off=+1).
local function build_block_single_assembler(recipe_node, offset_x, offset_y, settings, en, list, cache)
  local mach_name = get_machine_name(recipe_node, cache)
  if not mach_name then return nil end
  -- Не chemplant и не refinery — у них свои функции
  if is_chemplant_like(mach_name) then
    _diag_log("[BFH-single] SKIP "..tostring(mach_name)..": chemplant_like")
    return nil
  end
  if mach_name == "oil-refinery" then
    _diag_log("[BFH-single] SKIP "..tostring(mach_name)..": oil-refinery")
    return nil
  end

  local W, H = get_entity_size(mach_name)
  if not W or not H then return nil end

  local solid_ing  = get_ingredient_names(recipe_node)
  local solid_prod = get_solid_products(recipe_node)
  local f_ing      = get_fluid_ingredients(recipe_node)
  local f_prod     = get_fluid_products(recipe_node)
  local ing_count  = #solid_ing
  local prod_count = #solid_prod

  -- Если машина будет повёрнута горизонтально (dir=W/E, ставится при наличии жидкости),
  -- её ширина и высота на поле меняются местами. Учитываем это для раскладки.
  local has_fluid = (#f_ing > 0 or #f_prod > 0)
  if has_fluid and W ~= H then
    W, H = H, W
  end

  _diag_log(string.format("[BFH-single] %s: ing=%d prod=%d f_ing=%d f_prod=%d W=%d H=%d",
    tostring(mach_name), ing_count, prod_count, #f_ing, #f_prod, W, H))

  -- Поддерживаем любой одиночный блок: 1-N твёрд. ингр., 0-N твёрд. прод., жидкости.
  if ing_count < 1 and #f_ing == 0 then
    _diag_log("[BFH-single] SKIP: нет входов")
    return nil
  end
  _diag_log("[BFH-single] СТРОЮ одиночный блок (ing="..ing_count..", prod="..prod_count..
            ", f_ing="..#f_ing..", f_prod="..#f_prod..")")

  local belt_in  = settings.belt_in  or "transport-belt"
  local belt_out = settings.belt_out or "transport-belt"
  local ug_belt  = to_underground(belt_in)
  local ins_in   = settings.inserter_in  or "fast-inserter"
  local ins_out  = settings.inserter_out or "fast-inserter"
  local pipe_name = settings.pipe or "pipe"
  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  -- УНИВЕРСАЛЬНАЯ одиночная схема, БЕЗ splitter'ов:
  --   • Твёрдые ВХОДЫ — инсертеры на ЛЕВОЙ грани машины, каждый со своей лентой-входом.
  --   • Твёрдые ВЫХОДЫ — инсертеры на ПРАВОЙ грани машины, каждый со своей лентой-выхода.
  --   • Жидкости — трубы по точкам подключения fluidbox машины.
  -- Число инсертеров по грани не превышает H. Если ингредиентов/продуктов больше H — неудача.
  -- Число инсертеров входа = ceil(N/2). Если оно или число продуктов больше высоты грани —
  -- не помещается, уходим в общую ветку.
  -- Число инсертеров входа = ceil(N/2). До 3 помещаются на левой грани (если H>=3).
  -- 7-8 ингр (4 инсертера) тоже строим: 4-й уходит на нижнюю грань машины.
  local need_ins = math.ceil(ing_count / 2)
  if need_ins > 4 or (need_ins <= 3 and need_ins > H) or prod_count > H then
    _diag_log(string.format("[BFH-single] SKIP: инсертеров=%d prod=%d H=%d (не помещается)",
      need_ins, prod_count, H))
    return nil
  end
  _diag_log(string.format("[BFH-single] OK вход: ing=%d prod=%d W=%d H=%d f_ing=%d f_prod=%d",
    ing_count, prod_count, W, H, #f_ing, #f_prod))

  -- Ширина левой части: лента-вход (1) на каждый ингредиент идёт слева, но мы кладём
  -- по одной вертикальной ленте на колонку. Берём left_w = max(2, ing_count+1) чтобы
  -- разместить ленты + столбец инсертеров.
  -- Левая часть: вмещает Т-стыки и подземки (до 6 столбцов влево для 5-6 ингр + трубы).
  -- Правая часть: вмещает инсертер выхода, ленту и трубу выхода жидкости (до +2).
  local k_lines = math.ceil(ing_count / 2)
  local left_w  = math.max(3, k_lines + 4)   -- запас под Т-стыки/подземки/трубу входа
  local right_w = (#f_prod > 0) and 4 or 3   -- труба выхода на +2 при жидком продукте
  local header_h = math.max(2, 2 * k_lines)  -- Т-стыки уходят вверх на 2*k строк
  -- Для 7-8 ингр 4-й инсертер на нижней грани со змейкой — нужен запас снизу (до H+2).
  local footer_h = (ing_count >= 7) and 3 or 0
  local total_w = left_w + W + right_w
  local total_h = header_h + H + footer_h

  local mach_L_x = offset_x + left_w
  local mach_top_y = offset_y + header_h
  local mach_R_edge = mach_L_x + W

  -- Машина
  local mach_extra
  if recipe_node.name and prototypes.recipe[recipe_node.name] then
    mach_extra = { recipe = recipe_node.name }
  end
  -- Направление машины: выбираем поворот так, чтобы ВХОД жидкости оказался на ЛЕВОЙ грани
  -- (к трубе подачи слева). У разных машин fluidbox-входы на разных сторонах базовой модели,
  -- поэтому нужен разный поворот (chemical-plant→W, fuel-refinery→E и т.д.). Без жидкости — N.
  local mach_dir = defines.direction.north
  if #f_ing > 0 or #f_prod > 0 then
    mach_dir = dir_e  -- запасной вариант
    for _, try_dir in ipairs({ defines.direction.north, dir_e, defines.direction.south, dir_w }) do
      local cs = get_fluid_connections(mach_name, W, H, try_dir)
      local in_left = false
      for _, c in ipairs(cs) do
        if c.kind ~= "output" and c.dir == dir_w then in_left = true; break end
      end
      if in_left then mach_dir = try_dir; break end
    end
    -- если нет жидкого входа (только выход) — ориентируем так, чтобы ВЫХОД был справа
    if #f_ing == 0 and #f_prod > 0 then
      for _, try_dir in ipairs({ defines.direction.north, dir_e, defines.direction.south, dir_w }) do
        local cs = get_fluid_connections(mach_name, W, H, try_dir)
        local out_right = false
        for _, c in ipairs(cs) do
          if c.kind == "output" and c.dir == dir_e then out_right = true; break end
        end
        if out_right then mach_dir = try_dir; break end
      end
    end
  end
  en = add_entity_cell(list, en, mach_name, mach_L_x, mach_top_y, W, H, mach_dir, mach_extra, 0, 0)

  local meta = {
    offset_x = offset_x, offset_y = offset_y,
    width = total_w, height = total_h,
    is_single_assembler_block = true,
    fluid_inputs = {}, fluid_outputs = {},
    ingredients = solid_ing, products = solid_prod,
    inputs = {}, product_out = nil,
  }

  -- ── Твёрдые ВХОДЫ ──
  local ins_col = mach_L_x - 1
  local function _belt(dx, dy, d) en = add_entity_cell(list, en, belt_in, mach_L_x+dx, mach_top_y+dy, 1,1, d, nil, 0,0) end
  local function _ug(dx, dy, t)   en = add_entity_cell(list, en, ug_belt,  mach_L_x+dx, mach_top_y+dy, 1,1, dir_s, {type=t}, 0,0) end
  local function _ins(dx, dy)     en = add_entity_cell(list, en, ins_in,   mach_L_x+dx, mach_top_y+dy, 1,1, dir_w, nil, 0,0) end
  if ing_count == 7 or ing_count == 8 then
    -- 7-8 ингр: база как 6 ингр (3 инсертера на левой грани, каскад), ПЛЮС 4-й инсертер на
    -- НИЖНЕЙ грани машины со змейкой-подводом. При 8 — к нему 2 линии (Т-стык-слияние),
    -- при 7 — 1 линия (одиночная, остаток). Проверено на 3x3 (8 ингр, 0 расхождений).
    -- База 6-ингр:
    _ins(-1, 0); _ins(-1, 1); _ins(-1, 2)
    _belt(-5,-5,dir_e); _belt(-4,-5,dir_s); _belt(-3,-5,dir_w); _ug(-4,-4,"input")
    _belt(-4,-3,dir_e); _belt(-3,-3,dir_s); _belt(-2,-3,dir_w); _ug(-3,-2,"input")
    _belt(-3,-1,dir_e); _belt(-2,-1,dir_s); _belt(-1,-1,dir_w)
    _ug(-3,0,"output"); _belt(-2,0,dir_e)
    _ug(-4,1,"output"); _belt(-3,1,dir_e); _belt(-2,1,dir_e)
    _belt(-4,2,dir_e); _belt(-3,2,dir_e); _belt(-2,2,dir_e)
    -- 4-й инсертер на нижней грани (клетка под машиной, столбец 0), смотрит в машину (S)
    en = add_entity_cell(list, en, ins_in, mach_L_x+0, mach_top_y+H, 1,1, dir_s, nil, 0,0)
    if ing_count == 8 then
      -- 8 ингр: повёрнутый Т-стык (2 ресурса) — две линии вливаются к инсертеру снизу
      _belt(-2, H, dir_e); _belt(-1, H, dir_s)
      _belt(-1, H+1, dir_e); _belt(0, H+1, dir_n)
      _belt(-2, H+2, dir_e); _belt(-1, H+2, dir_n)
    else
      -- 7 ингр: одиночная прямая линия снизу (1 ресурс) → инсертер
      _belt(-2, H+1, dir_e); _belt(-1, H+1, dir_e); _belt(0, H+1, dir_n)
    end
    for i = 1, ing_count do meta.inputs[i] = { x = mach_L_x-5, y = mach_top_y-5, ingredient = solid_ing[i] } end
  elseif ing_count == 5 or ing_count == 6 then
    -- ЕДИНАЯ раскладка 5-6 ингр (3 инсертера на грани 0,1,2). Каскад Т-стыков ступенькой
    -- сверху, подземки выводят к инсертерам ступенькой. При 5 ингр верхняя линия одиночная
    -- (остаток). Проверено на 3x3 (6 ингр), 0 расхождений. (5-6 — только 3x3, без жидк. входа.)
    _ins(-1, 0); _ins(-1, 1); _ins(-1, 2)
    -- Линия 3 (верхняя, инсертер 0): Т-стык(-5,-5) или одиночная при 5, подземка (-4,-4)→(-3,0)
    if ing_count == 6 then
      _belt(-5,-5,dir_e); _belt(-4,-5,dir_s); _belt(-3,-5,dir_w)
    else
      _belt(-4,-5,dir_s)   -- 5 ингр: одиночная (остаток)
    end
    _ug(-4,-4,"input")
    -- Линия 2 (средняя, инсертер 1): Т-стык(-4,-3), подземка (-3,-2)→(-4,1)
    _belt(-4,-3,dir_e); _belt(-3,-3,dir_s); _belt(-2,-3,dir_w)
    _ug(-3,-2,"input")
    -- Линия 1 (нижняя, инсертер 2): Т-стык(-3,-1) напрямую вниз
    _belt(-3,-1,dir_e); _belt(-2,-1,dir_s); _belt(-1,-1,dir_w)
    -- Выходы подземок ступенькой к инсертерам:
    _ug(-3,0,"output"); _belt(-2,0,dir_e)                       -- → инсертер 0
    _ug(-4,1,"output"); _belt(-3,1,dir_e); _belt(-2,1,dir_e)    -- → инсертер 1
    _belt(-4,2,dir_e); _belt(-3,2,dir_e); _belt(-2,2,dir_e)     -- → инсертер 2
    for i = 1, ing_count do meta.inputs[i] = { x = mach_L_x-5, y = mach_top_y-5, ingredient = solid_ing[i] } end
  elseif ing_count == 3 or ing_count == 4 then
    -- 3-4 ингр: инсертеры на краях грани (верх 0, низ H-1). Верхняя линия — Т-стык.
    -- Нижняя линия (по столбцу -4 через подземку): Т-стык при 4 ингр, одиночная лента при 3.
    -- Различие ровно в боковых лентах нижнего Т-стыка. Привязка к грани. Проверено на 3x3.
    local bot = H - 1
    _ins(-1, 0); _ins(-1, bot)
    -- Верхняя линия → инсертер (-1,0): Т-стык
    _belt(-3,-2,dir_e); _belt(-2,-2,dir_s); _belt(-1,-2,dir_w)
    _belt(-2,-1,dir_s); _belt(-2,0,dir_e)
    -- Нижняя линия → инсертер (-1,bot): подземка по столбцу -4, ленты к инсертеру
    if ing_count == 4 then
      -- Т-стык на нижней линии (2 ресурса)
      _belt(-5,-4,dir_e); _belt(-4,-4,dir_s); _belt(-3,-4,dir_w)
    else
      -- одиночная лента (1 ресурс)
      _belt(-4,-4,dir_s)
    end
    _ug(-4,-3,"input"); _ug(-4,bot-1,"output")
    _belt(-4,bot,dir_e); _belt(-3,bot,dir_e); _belt(-2,bot,dir_e)
    meta.inputs[1] = { x = mach_L_x-3, y = mach_top_y-2, ingredient = solid_ing[1] }
    meta.inputs[2] = { x = mach_L_x-1, y = mach_top_y-2, ingredient = solid_ing[2] }
    meta.inputs[3] = { x = mach_L_x-(ing_count == 4 and 3 or 4), y = mach_top_y-4, ingredient = solid_ing[3] }
    if solid_ing[4] then meta.inputs[4] = { x = mach_L_x-5, y = mach_top_y-4, ingredient = solid_ing[4] } end
  elseif ing_count == 0 then
    -- Нет твёрдых ингредиентов (только жидкие) — вход твёрдых НЕ строим (ни Т-стыков, ни лент,
    -- ни инсертеров). Подаётся только жидкость трубами (ниже).
  elseif ing_count == 1 then
    -- 1 ингр: БЕЗ Т-стыка — одна лента сверху вниз → инсертер у верха грани.
    _ins(-1, 0)
    _belt(-2,-1,dir_s); _belt(-2,0,dir_e)
    meta.inputs[1] = { x = mach_L_x-2, y = mach_top_y-1, ingredient = solid_ing[1] }
  elseif ing_count == 2 then
    -- Dedicated belts and inserters retain both lanes for each ingredient.
    -- Do not combine two full-rate inputs onto the two lanes of one belt.
    _ins(-1,0);_ins(-1,H-1)
    _belt(-2,0,dir_e);_belt(-2,H-1,dir_e)
    meta.inputs[1]={x=mach_L_x-2,y=mach_top_y,ingredient=solid_ing[1]}
    meta.inputs[2]={x=mach_L_x-2,y=mach_top_y+H-1,ingredient=solid_ing[2]}
  else
    for i = 1, ing_count do
      local iy = mach_top_y + (i - 1)
      local belt_col = mach_L_x - 1 - i
      for y = offset_y, iy do
        en = add_entity_cell(list, en, belt_in, belt_col, y, 1, 1, dir_s, nil, 0, 0)
      end
      for x = belt_col + 1, ins_col - 1 do
        en = add_entity_cell(list, en, belt_in, x, iy, 1, 1, dir_e, nil, 0, 0)
      end
      en = add_entity_cell(list, en, ins_in, ins_col, iy, 1, 1, dir_w, nil, 0, 0)
      meta.inputs[i] = { x = belt_col, y = offset_y, ingredient = solid_ing[i] }
    end
  end

  -- ── Твёрдый ВЫХОД (как эталон): один инсертер на нижней правой грани → лента вниз.
  -- Жидкие продукты выводятся трубами (ниже). Доп. твёрдые продукты (побочные) — не выводим
  -- отдельной лентой, чтобы не плодить мешанину; основной продукт идёт на ленту-выход.
  if prod_count >= 1 then
    local jy = mach_top_y + H - 1           -- нижняя строка грани (как эталон y=+8)
    local belt_col = mach_R_edge + 1
    en = add_entity_cell(list, en, ins_out, mach_R_edge, jy, 1, 1, dir_w, nil, 0, 0)
    -- лента вниз от строки инсертера до низа блока. Для 7-8 ингр (нижняя подача на строке H+1)
    -- выход заканчивается на той же горизонтали, что подающая лента снизу — не ниже.
    local target_out_y = offset_y + total_h
    if ing_count == 7 then
      target_out_y = mach_top_y + H + 2      -- 7 ингр: подача снизу на H+1 → выход до H+1
    elseif ing_count == 8 then
      target_out_y = mach_top_y + H + 3      -- 8 ингр: Т-стык снизу на H+2 → выход до H+2
    end
    for y = jy, target_out_y - 1 do
      en = add_entity_cell(list, en, belt_out, belt_col, y, 1, 1, dir_s, nil, 0, 0)
    end
    if ing_count<=2 and #f_ing==0 and #f_prod==0 and prod_count==1 then
      local flow=0;for _,item in ipairs(recipe_node.products or {}) do flow=flow+get_flow_per_sec(item,recipe_node) end
      if flow>belt_throughput(belt_out)/2+1e-8 then
        local x=mach_L_x+math.floor(W/2);local by=jy+2
        en=add_entity_cell(list,en,ins_out,x,jy+1,1,1,dir_n,nil,0,0)
        for bx=x,belt_col-1 do en=add_entity_cell(list,en,belt_out,bx,by,1,1,dir_e,nil,0,0) end
        for y=target_out_y,by do en=add_entity_cell(list,en,belt_out,belt_col,y,1,1,dir_s,nil,0,0) end
        target_out_y=math.max(target_out_y,by+1)
        total_h=math.max(total_h,target_out_y-offset_y);meta.height=total_h
      end
    end
    meta.product_out = { x = belt_col, y = target_out_y }
  end

  -- ── Жидкости: трубы по РЕАЛЬНЫМ точкам подключения fluidbox машины (из прототипа).
  -- Строка трубы = строка точки fluidbox (не середина грани) — корректно для машин с
  -- несимметричными точками (топливный завод и т.п.). Вход слева, выход справа.
  if #f_ing > 0 or #f_prod > 0 then
    local pipe_ug = to_pipe_underground(pipe_name)
    local conns = get_fluid_connections(mach_name, W, H, mach_dir)
    -- собираем строки входных и выходных точек на левой/правой гранях
    local in_rows, out_rows = {}, {}
    for _, c in ipairs(conns) do
      if c.kind == "output" then out_rows[#out_rows+1] = c.dy
      else in_rows[#in_rows+1] = c.dy end
    end
    -- запасной вариант — середина грани, если прототип не дал точек
    local midy_rel = math.floor(H / 2)
    -- вход жидкости — слева, на строке точки fluidbox
    if #f_ing > 0 then
      local rel = in_rows[1] or midy_rel
      local yy = mach_top_y + rel
      en = add_entity_cell(list, en, pipe_ug, mach_L_x - 3, yy, 1, 1, dir_w, nil, 0, 0)  -- наружу
      en = add_entity_cell(list, en, pipe_ug, mach_L_x - 1, yy, 1, 1, dir_e, nil, 0, 0)  -- к машине
      meta.fluid_inputs[1] = { x = mach_L_x - 3, y = yy, dir = dir_w, ingredient = f_ing[1] }
    end
    -- выход жидкости — справа, на строке точки fluidbox
    if #f_prod > 0 then
      local rel = out_rows[1] or midy_rel
      local yy = mach_top_y + rel
      en = add_entity_cell(list, en, pipe_ug, mach_R_edge,     yy, 1, 1, dir_w, nil, 0, 0)  -- к машине
      en = add_entity_cell(list, en, pipe_ug, mach_R_edge + 2, yy, 1, 1, dir_e, nil, 0, 0)  -- наружу
      meta.fluid_outputs[1] = { x = mach_R_edge + 2, y = yy, dir = dir_e, product = f_prod[1] }
    end
  end

  return en, total_h, meta
end


-- ── Многозаводной блок для машин с жидкостью (fuel-refinery и подобные) ──
-- Сетка N строк × 2 столбца. Левый столбец dir=E, правый dir=W (зеркально, навстречу).
-- Вход жидкости — вертикальные трубы-магистрали по внешним краям, отводы PTG к точкам
-- fluidbox каждой машины. Твёрдый выход — инсертеры в центральном зазоре, лента вниз.
local function build_block_fluid_grid(recipe_node, offset_x, offset_y, settings, en, list, cache)
  local name=get_machine_name(recipe_node,cache)
  local W,H=get_entity_size(name)
  local count=get_machine_count(recipe_node)
  local fluid_inputs=get_fluid_ingredients(recipe_node)
  local products=get_solid_products(recipe_node)
  if count<2 or #get_ingredient_names(recipe_node)>0 or #fluid_inputs==0
    or #get_fluid_products(recipe_node)>0 or #products==0 then return nil end
  local function facing(side)
    for _,d in ipairs({0,4,8,12}) do
      for _,c in ipairs(get_fluid_connections(name,W,H,d)) do
        if c.kind~='output' and c.dir==side then return d end
      end
    end
  end
  local small_pair=count==2 and settings.link_mode~='independent'
  local left_dir,right_dir=facing(small_pair and 4 or 12),facing(small_pair and 12 or 4)
  if not left_dir or not right_dir then return nil end
  local left=offset_x+4
  local right=left+W+3
  local middle=left+W+1
  local top=offset_y+2
  local rows=math.ceil(count/2)
  local belt=settings.belt_out or 'transport-belt'
  local arm=settings.inserter_out or 'fast-inserter'
  if small_pair then
    local side_l,side_r=left-2,right+W+1
    en=add_entity_cell(list,en,name,left,top,W,H,left_dir,{recipe=recipe_node.name},0,0)
    en=add_entity_cell(list,en,name,right,top,W,H,right_dir,{recipe=recipe_node.name},0,0)
    for y=top,top+H-1 do
      en=add_entity_cell(list,en,belt,side_l,y,1,1,8,nil,0,0)
      en=add_entity_cell(list,en,belt,side_r,y,1,1,8,nil,0,0)
    end
    en=add_entity_cell(list,en,arm,left-1,top+H-1,1,1,4,nil,0,0)
    en=add_entity_cell(list,en,arm,right+W,top+H-1,1,1,12,nil,0,0)
    for x=side_l,side_r do en=add_entity_cell(list,en,belt,x,top+H,1,1,x==side_l and 8 or 12,nil,0,0)end
    return en,H+3,{offset_x=offset_x,offset_y=offset_y,width=2*W+10,height=H+3,
      ingredients={},products=products,inputs={},product_out={x=side_l,y=top+H,direction=8},
      fluid_inputs={},fluid_outputs={},is_fluid_grid_block=true}
  end
  -- Fluid inputs face outwards. Unload towards the shared inner belt, so no
  -- inserter occupies a fluid mouth. The prototype-based planner builds pipes.
  for row=0,rows-1 do
    local y=top+row*H
    local iy=row%2==0 and y+H-1 or y
    en=add_entity_cell(list,en,name,left,y,W,H,left_dir,{recipe=recipe_node.name},0,0)
    en=add_entity_cell(list,en,arm,left+W,iy,1,1,12,nil,0,0)
    if row*2+2<=count then
      en=add_entity_cell(list,en,name,right,y,W,H,right_dir,{recipe=recipe_node.name},0,0)
      en=add_entity_cell(list,en,arm,right-1,iy,1,1,4,nil,0,0)
    end
  end
  for y=top,top+rows*H do
    en=add_entity_cell(list,en,belt,middle,y,1,1,8,nil,0,0)
  end
  return en,rows*H+3,{
    offset_x=offset_x,offset_y=offset_y,width=2*W+10,height=rows*H+3,
    ingredients={},products=products,inputs={},
    product_out={x=middle,y=top+rows*H,direction=8},
    fluid_inputs={},fluid_outputs={},is_fluid_grid_block=true,
  }
end


-- ── Генерация одного блока ───────────────────────────────────
local function build_block(recipe_node, offset_x, offset_y, settings, en, list, cache, beacon_bay)
  -- Специальная ветка: нефтезавод с чисто-жидкостным рецептом
  -- (без твёрдых входов и без твёрдых выходов).
  do
    local mach_check = get_machine_name(recipe_node, cache)
    if mach_check == "oil-refinery" then
      local solid_ingr = get_ingredient_names(recipe_node)
      local solid_prod = get_solid_products(recipe_node)
      if #solid_ingr == 0 and #solid_prod == 0 then
        return build_block_refinery(recipe_node, offset_x, offset_y, settings, en, list, cache, nil)
      end
    end
  end

  -- Специальная ветка: химзавод с 1 МАШИНОЙ (без зеркала справа).
  -- Приоритет выше chem_fluid: для 1 машины (даже чисто-жидкостной) используется
  -- упрощённая схема с подземками вместо стояков.
  do
    local count_check = get_machine_count(recipe_node)
    local mach_check = get_machine_name(recipe_node, cache)
    if count_check == 1 and is_chemplant_like(mach_check) then
      local result_en, result_h, result_meta = build_block_single_chem(
        recipe_node, offset_x, offset_y, settings, en, list, cache)
      if result_en ~= nil then
        return result_en, result_h, result_meta
      end
    end
  end

  -- Специальная ветка: химзавод с ЧИСТО ЖИДКОСТНЫМ рецептом, 2+ машины.
  do
    local mach_check = get_machine_name(recipe_node, cache)
    if is_chemplant_like(mach_check) then
      local solid_ingr = get_ingredient_names(recipe_node)
      local solid_prod = get_solid_products(recipe_node)
      if #solid_ingr == 0 and #solid_prod == 0 then
        return build_block_chem_fluid(recipe_node, offset_x, offset_y, settings, en, list, cache)
      end
    end
  end

  -- Специальная ветка: машина с ЖИДКИМ входом + ТВЁРДЫМ выходом, 2+ машины
  -- (fuel-refinery и подобные) — сетка N×2 зеркально, магистрали жидкости, выход в зазоре.
  do
    local count_check = get_machine_count(recipe_node)
    if count_check >= 2 then
      local result_en, result_h, result_meta = build_block_fluid_grid(
        recipe_node, offset_x, offset_y, settings, en, list, cache)
      if result_en ~= nil then
        return result_en, result_h, result_meta
      end
    end
  end

  -- Специальная ветка: СБОРОЧНАЯ машина с 1 МАШИНОЙ (не chemplant) — компактная схема.
  do
    local count_check = get_machine_count(recipe_node)
    local mach_dbg = get_machine_name(recipe_node, cache)
    _diag_log(string.format("[BFH-dispatch] машина=%s count=%s chemlike=%s",
      tostring(mach_dbg), tostring(count_check), tostring(is_chemplant_like(mach_dbg))))
    if count_check == 1 then
      local result_en, result_h, result_meta = build_block_single_assembler(
        recipe_node, offset_x, offset_y, settings, en, list, cache)
      if result_en ~= nil then
        return result_en, result_h, result_meta
      end
    end
  end

  local mach_name = get_machine_name(recipe_node, cache)
  local W, H      = get_entity_size(mach_name)
  local count     = get_machine_count(recipe_node)
  local ingr      = get_ingredient_names(recipe_node)
  local ing_count = math.min(#ingr, 4)

  -- Валидация
  if not entity_exists(settings.belt_in)      then settings.belt_in      = "transport-belt" end
  if not entity_exists(settings.belt_out)     then settings.belt_out     = "transport-belt" end
  if not entity_exists(settings.inserter_in)  then settings.inserter_in  = "fast-inserter"  end
  if not entity_exists(settings.inserter_out) then settings.inserter_out = "fast-inserter"  end
  local pipe_main_name = settings.pipe or "pipe"
  local pipe_ug_name = to_pipe_underground(pipe_main_name)

  -- Проверка: есть ли жидкий ингредиент в рецепте
  local has_fluid = has_fluid_ingredient(recipe_node)

  -- Ширина блока зависит от количества ингредиентов и ширины машины:
  --   1-2 ингр.: width = 2*W + 7
  --   3-4 ингр.: width = 2*W + 9 (по 1 доп. клетке с каждой стороны для внутренних лент)
  --
  -- ВАЖНО для 3-4 ингр.: схема шапки рассчитана на W=3. При W<3 (например, печь 2x2)
  -- расчётный c_split_R_L = c_mach_R_left - 3 = (width-3-W) - 3 совпадает с c_h_ug_L
  -- (горизонтальная подземка ингр.3+4) → коллизия. Поэтому минимальная ширина для
  -- 3-4 ингр. соответствует W=3, т.е. >= 15 (или 19 с жидкостью).
  -- Если есть жидкий ингредиент, добавляем 4 столбца (по 2 с каждой стороны для труб):
  local width
  if ing_count >= 3 then
    width = 2 * math.max(W, 3) + 9 + (beacon_bay and beacon_bay + 1 or 0)
  else
    width = 2 * W + 7
  end
  local fluid_offset = 0  -- сдвиг твёрдой части блока вправо если есть труба слева
  if has_fluid then
    width = width + 4
    fluid_offset = 2  -- лента/шапка/машины сдвигаются на 2 вправо
  end

  -- body_y — где начинается первая пара машин.
  -- Для 1-2 ингр.: y >= 3 (после шапки H=3) и нижний ряд машины >= 5
  -- Для 3-4 ингр.: y >= 6 (после шапки H=6)
  local body_start
  if ing_count >= 3 then
    body_start = 6                 -- шапка для 3-4 ингр. занимает y=0..5
  else
    body_start = ing_count<=1 and HEADER_HEIGHT or math.max(HEADER_HEIGHT, 5 - H + 1)
  end

  -- Если есть жидкость — твёрдая часть (шапка, тело, ленты) сдвигается на fluid_offset
  -- и работает с уменьшенной шириной (без столбцов труб по краям)
  local solid_width = width - 2 * fluid_offset
  local solid_offset_x = offset_x + fluid_offset

  -- Шапка
  if ing_count == 1 then
    en = build_header_1ing(solid_width, settings.belt_in, solid_offset_x, offset_y, en, list)
  elseif ing_count == 2 then
    en = build_header_2ing(solid_width, settings.belt_in, solid_offset_x, offset_y, en, list)
  elseif ing_count >= 3 then
    en = build_header_34ing(solid_width, W, settings.belt_in, solid_offset_x, offset_y, en, list)
  end
  -- Если ing_count == 0 (рецепт с одними флюидами) — шапки нет

  -- Short machines require a lower body to keep the two-input header clear.
  -- Fill both feeder columns between the header and body, without duplicating
  -- the belts already emitted by either template.
  if ing_count>0 then
    local header_last_y=ing_count>=3 and 5 or 2
    for y=header_last_y+1,body_start-1 do
      en=add_entity_cell(list,en,settings.belt_in,0,y,1,1,defines.direction.south,nil,solid_offset_x,offset_y)
      en=add_entity_cell(list,en,settings.belt_in,solid_width-1,y,1,1,defines.direction.south,nil,solid_offset_x,offset_y)
    end
  end

  -- Считаем твёрдые продукты — нужно для пропуска манипуляторов-выходов и
  -- центральной ленты, если продукты только жидкие.
  local solid_products = get_solid_products(recipe_node)
  local prod_count = #solid_products

  -- Тело
  local body_h
  en, body_h = build_body(
    recipe_node, count, solid_width, W, H,
    settings.belt_in, settings.belt_out, settings.inserter_in, settings.inserter_out,
    recipe_node.name, mach_name, ing_count, prod_count,
    body_start, solid_offset_x, offset_y, en, list, has_fluid, beacon_bay
  )

  -- Mixed beacon banks use the prototype-driven pipe router directly.
  if has_fluid and not beacon_bay then
    local total_h = body_start + body_h

    -- Helper: проверка занятости клетки
    local function cell_free(cx, cy)
      for _, e in ipairs(list) do
        local px = e.position.x
        local py = e.position.y
        local proto = prototypes.entity[e.name]
        local ew = (proto and proto.tile_width)  or 1
        local eh = (proto and proto.tile_height) or 1
        local ex = math.floor(px - ew / 2 + 0.001)
        local ey = math.floor(py - eh / 2 + 0.001)
        if cx >= ex and cx < ex + ew and cy >= ey and cy < ey + eh then
          return false
        end
      end
      return true
    end

    local function safe_ptog(cx, cy, dir)
      if cell_free(cx, cy) then
        en = add_entity_cell(list, en, pipe_ug_name, cx, cy, 1, 1, dir, nil, 0, 0)
      end
    end

    -- Сдвиг по горизонтали (для шапочных подземок)
    local function safe_ptog_hshift(cx, cy, dir, dx)
      for attempt = 0, 2 do
        if cell_free(cx + dx * attempt, cy) then
          en = add_entity_cell(list, en, pipe_ug_name, cx + dx * attempt, cy, 1, 1, dir, nil, 0, 0)
          return
        end
      end
    end

    -- Сдвиг по вертикали (для подземок у машин)
    local function safe_ptog_vshift(cx, cy, dir)
      for attempt = 0, 2 do
        if cell_free(cx, cy + attempt) then
          en = add_entity_cell(list, en, pipe_ug_name, cx, cy + attempt, 1, 1, dir, nil, 0, 0)
          return
        end
      end
    end

    -- Считаем последние пары, у которых есть машина с этой стороны.
    -- На каждую пару подземка трубы для машины ставится на middle_y = row_top + floor(H/2).
    -- Трубопровод-стояк должен обрезаться по последней подземке этой стороны
    -- (включая шапочную ptog на header_pipe_y=1) — лишние клетки трубы не нужны.
    local n_machines = count
    local n_pairs    = math.ceil(n_machines / 2)
    local last_pair_L = n_pairs - 1                              -- левая машина есть в каждой паре
    local last_pair_R = math.floor(n_machines / 2) - 1   -- правая машина: pair_i*2+2 ≤ count
    local function pair_pipe_y(pair_i)
      local row_top = body_start + pair_i * H
      if is_chemplant_like(mach_name) then
        if pair_i % 2 == 0 then
          return row_top + H - 1   -- нижняя точка (y_off=+1)
        else
          return row_top           -- верхняя точка (y_off=-1)
        end
      else
        return row_top + math.floor(H / 2)
      end
    end
    local last_y_L = pair_pipe_y(last_pair_L)
    local last_y_R = (last_pair_R >= 0) and pair_pipe_y(last_pair_R) or 1  -- хотя бы шапка

    -- Труба-стояк по краям блока: обрезается раздельно по последней подземке стороны
    for y = 1, last_y_L do
      if cell_free(offset_x + 0, offset_y + y) then
        en = add_entity_cell(list, en, pipe_main_name, offset_x + 0, offset_y + y, 1, 1, 0, nil, 0, 0)
      end
    end
    for y = 1, last_y_R do
      if cell_free(offset_x + width - 1, offset_y + y) then
        en = add_entity_cell(list, en, pipe_main_name, offset_x + width - 1, offset_y + y, 1, 1, 0, nil, 0, 0)
      end
    end
    -- Жидкий вход у машины assembling-machine — на верхней грани, X = центр машины.
    -- Машины стоят парами, между парами есть промежуток (фактически нет — стоят вплотную H=3 → 6,9,12,15...).
    -- Подземные трубы соединяют верх машины с трубой на краю блока через проход между парами.
    -- Но в эталоне видно: входы машин жидкости НА ВЕРХНЕЙ ГРАНИ. Машина 1 (top y=row_top, центр x_center=2..4 → 3),
    -- значит fluid_in = (X=center, Y=row_top - 1)? Нет, fluid_box у assembling-machine-2 на (0,-1) от центра при dir=N,
    -- т.е. (X=center_x, Y=center_y-1)... но в эталоне показано что вход СВЕРХУ машины на её центре.
    --
    -- Фактически: у assembling-machine-2 жидкий вход на (X=center_x, Y=top_y-1), что = клетка прямо над центром.
    -- Машина с dir=N, top-left = (solid_offset_x+2, row_top), centre = (solid_offset_x+3, row_top+1).
    -- Fluid input: (solid_offset_x+3, row_top - 1) — клетка над верхним рядом.
    --
    -- Но в эталоне вижу что трубы НЕ идут сверху над каждой машиной, а используют боковые подземки.
    -- Перепрограммирую по факту с эталона: подземные трубы есть только при первой и последней паре машин,
    -- остальные машины получают жидкость через цепочку соединённых труб через **верх** машины.
    --
    -- Проще: ставлю одну трубу прямо над каждой машиной на (machine_center_x, row_top - 1).
    -- Эти трубы соединяются с боковой трубой через горизонтальный коридор (но коридора нет — машины вплотную).
    -- Значит надо использовать pipe-to-ground.
    --
    -- В эталоне 1ing+1fluid вижу: подземки слева (X=1, X=4) и справа (X=14, X=17) на y=7,10,13,16.
    -- У меня машины во 2-4 столбцах слева (solid_offset_x+2..+4) и в 11-13 столбцах справа (solid_offset_x+11..+13).
    -- При solid_offset_x = 2: машины на X=4..6 и X=11..13.
    -- Тогда подземные трубы на (X=1, Y=middle) west вход, (X=4, Y=middle) east выход (под машину сбоку),
    -- (X=14, Y=middle) east выход (под машину сбоку), (X=17, Y=middle) east вход.
    -- (X=4, middle) — это **левая клетка машины** или **выход прямо в стену машины**? У машины top-left=(4,row_top),
    -- значит (X=4, middle_y=row_top+1) — это сама машина! Подземка туда не поставится.
    -- Должно быть (X=3, middle_y) — это слева от машины, и подземка туда выходит.
    -- Тогда эталон неправильный? Перепроверяю...
    --
    -- В эталоне 1ing+1fluid: машины на y=6..8 (row_top=6), машина top-left (5,6) (т.к. вижу M2W на (5..7, 6..8)).
    -- Значит solid_offset_x = 3 (1-2ing, fluid_offset=2, smth решилось). PtoG (4,7) east: это слева от машины (X=4)? Нет, машина заняла (5,6..8). Тогда (4,7) — клетка слева от машины, направление east = выходит в машину справа от себя = в (5,7) = центр машины. У машины assembling-machine-2 жидкий вход на левой грани = (X=top-left_x - 1, Y=center) = (4, 7) east. Это PtoG output dir=east на (4, 7) — соединяется с машиной слева.
    --
    -- Так что моя текущая логика верна для assembling-machine-2 при solid_offset_x=3.
    -- При solid_offset_x=2 (другой ing_count) машины на X=2..4 и подземка на X=1 east к ним.
    --
    -- Но это уже работает! Возможно проблема была в том что подземка снаружи неправильного направления.
    -- (n_machines, n_pairs, last_pair_L, last_pair_R уже вычислены выше для обрезки стояков)
    local mach_L_left  = solid_offset_x + 2
    local mach_R_left
    if ing_count >= 3 then
      mach_R_left = solid_offset_x + (solid_width - 3 - W)
    else
      mach_R_left = solid_offset_x + (solid_width - 2 - W)
    end

    -- Подземки в ШАПКЕ
    --
    -- Жидкость должна пройти через всю шапку слева направо:
    --   [стояк pipe] ↔ ptog(west) -подземно east→ ptog(east) ↔наземно↔ ptog(west) -подземно east→ ptog(east) ↔ [стояк pipe]
    --
    -- Чтобы ptog(east) и ptog(west) во внутренней паре передавали жидкость через свои НАЗЕМНЫЕ
    -- стороны, они должны стоять ВПЛОТНУЮ друг к другу: ptog(east).наземная_сторона(восточная грань)
    -- соприкасается с ptog(west).наземная_сторона(западная грань) только если расстояние = 1.
    --
    -- Также: расстояние под землёй между внешней (offset_x+1, west) и внутренней (inner_L, east)
    -- не должно превышать max_underground_distance (10 для ванильных труб). Аналогично справа.
    local header_pipe_y = 1
    local hpy = offset_y + header_pipe_y
    local outer_L_x = offset_x + 1
    local outer_R_x = offset_x + width - 2
    local PIPE_UG_MAX = 10  -- vanilla pipe-to-ground max_underground_distance
    -- Стартовая позиция пары (inner_L_x, inner_R_x = inner_L_x + 1) — около центра.
    local center_pair_L
    if ing_count >= 3 then
      local c_belt_C = W + 4
      center_pair_L = solid_offset_x + c_belt_C - 2
    else
      local c_split_L = math.floor((solid_width - 1) / 2) - 1
      center_pair_L = solid_offset_x + c_split_L + 2
    end

    -- Внешняя ЛЕВАЯ ptog: жидкость от стояка pipe(offset_x, ...) через наземную сторону.
    safe_ptog(outer_L_x, hpy, defines.direction.west)

    -- Размещение внутренних пар ptog так, чтобы вся шапка была проводящей слева направо.
    -- Каждая пара: (X, east) + (X+1, west) — стоят вплотную, наземные стороны навстречу.
    -- Дистанция под землёй между соседними узлами цепочки должна быть ≤ PIPE_UG_MAX.
    --
    -- Сначала пробуем 1 пару в центре. Если не получается (сплиттеры/подземки в центре + выход
    -- за max_distance) — ставим 2 пары: одну ближе к outer_L, другую ближе к outer_R.
    local function try_place_pair(L_x)
      local R_x = L_x + 1
      if not (cell_free(L_x, hpy) and cell_free(R_x, hpy)) then return false end
      if L_x <= outer_L_x or R_x >= outer_R_x then return false end
      en = add_entity_cell(list, en, pipe_ug_name, L_x, hpy, 1, 1,
        defines.direction.east, nil, 0, 0)
      en = add_entity_cell(list, en, pipe_ug_name, R_x, hpy, 1, 1,
        defines.direction.west, nil, 0, 0)
      return true
    end

    -- Найдём ВСЕ свободные пары (L, L+1) в диапазоне (outer_L_x+1 .. outer_R_x-2).
    -- Возвращаем список L-координат в порядке возрастания.
    local function find_free_pair_slots()
      local slots = {}
      for L_x = outer_L_x + 1, outer_R_x - 2 do
        if cell_free(L_x, hpy) and cell_free(L_x + 1, hpy) then
          slots[#slots + 1] = L_x
        end
      end
      return slots
    end

    local function place_pair_at(L_x)
      en = add_entity_cell(list, en, pipe_ug_name, L_x, hpy, 1, 1,
        defines.direction.east, nil, 0, 0)
      en = add_entity_cell(list, en, pipe_ug_name, L_x + 1, hpy, 1, 1,
        defines.direction.west, nil, 0, 0)
    end

    local slots = find_free_pair_slots()

    -- Попытка 1: одна пара в центре, обе дистанции ≤ max.
    local placed = false
    do
      -- предпочитаем slot ближе к center_pair_L
      local best, best_d
      for _, L_x in ipairs(slots) do
        if (L_x - outer_L_x) <= PIPE_UG_MAX and (outer_R_x - (L_x + 1)) <= PIPE_UG_MAX then
          local d = math.abs(L_x - center_pair_L)
          if not best_d or d < best_d then best_d = d; best = L_x end
        end
      end
      if best then place_pair_at(best); placed = true end
    end

    -- Попытка 2: две пары — одна ближе к outer_L, другая ближе к outer_R.
    -- Условия: pair1_L - outer_L_x ≤ MAX, pair2_R+1 - outer_R_x... т.е. outer_R - pair2_R ≤ MAX,
    -- и pair2_L - (pair1_L+1) ≤ MAX (расстояние между перемычками тоже под землёй).
    if not placed then
      for i = 1, #slots do
        local p1 = slots[i]
        if (p1 - outer_L_x) > PIPE_UG_MAX then break end  -- дальше уже слишком далеко от outer_L
        for j = i + 1, #slots do
          local p2 = slots[j]
          if p2 < p1 + 2 then  -- пары должны не пересекаться
            -- skip
          elseif (outer_R_x - (p2 + 1)) > PIPE_UG_MAX then
            -- p2 слишком близко к центру — продолжаем искать дальше
          elseif (p2 - (p1 + 1)) > PIPE_UG_MAX then
            -- между парами too far — следующий p2 ещё дальше, прервёмся
            break
          else
            place_pair_at(p1)
            place_pair_at(p2)
            placed = true
            break
          end
        end
        if placed then break end
      end
    end
    -- Если по-прежнему не получилось — оставляем без перемычки (жидкости не будет в этом блоке,
    -- но сборка не сломается).

    -- Внешняя ПРАВАЯ ptog
    safe_ptog(outer_R_x, hpy, defines.direction.east)

    for pair_i = 0, n_pairs - 1 do
      local row_top = body_start + pair_i * H
      local middle_y = row_top + math.floor(H / 2)

      if is_chemplant_like(mach_name) then
        -- Химзавод-подобная машина: точки соединения трубы на 1-й и 3-й клетках грани
        -- (y_off = ±1 от центра).
        -- Чтобы подземки разных пар "стремились друг к другу" (минимизировали разрыв
        -- стояка pipe между ними), используем правило:
        --   чётная пара (0, 2, ...) → нижняя точка (y_off=+1) → y = row_top + H - 1
        --   нечётная пара (1, 3, ...) → верхняя точка (y_off=-1) → y = row_top
        -- В блоке из 3 машин (pair 0 left+right, pair 1 left only) подземки слева:
        --   pair 0 (верхняя) на y = row_top0 + 2 (нижняя точка)
        --   pair 1 (нижняя)  на y = row_top1     (верхняя точка)
        -- Они на расстоянии 1 клетки → подземки соседние, что даёт компактную обвязку.
        local face_y
        if pair_i % 2 == 0 then
          face_y = row_top + H - 1     -- нижняя точка
        else
          face_y = row_top             -- верхняя точка
        end
        safe_ptog(offset_x + 1, offset_y + face_y, defines.direction.west)
        safe_ptog(mach_L_left - 1, offset_y + face_y, defines.direction.east)
        if pair_i <= last_pair_R then
          safe_ptog(mach_R_left + W, offset_y + face_y, defines.direction.west)
          safe_ptog(offset_x + width - 2, offset_y + face_y, defines.direction.east)
        end
      else
        -- Обычная машина (assembling-machine): точка соединения в центре грани (y_off=0)
        safe_ptog(offset_x + 1, offset_y + middle_y, defines.direction.west)
        safe_ptog(mach_L_left - 1, offset_y + middle_y, defines.direction.east)
        if pair_i <= last_pair_R then
          safe_ptog(mach_R_left + W, offset_y + middle_y, defines.direction.west)
          safe_ptog(offset_x + width - 2, offset_y + middle_y, defines.direction.east)
        end
      end
    end
  end

  -- Метаданные блока для последующего соединения с другими блоками.
  --
  -- Координаты входов в шапку зависят от ing_count и ширины блока.
  -- Для 1-2 ингр. (width = 2*W+7):
  --   c_split_L = floor((width-1)/2) - 1
  --   inputs[1] = { x = c_split_L, y = 0 }    (ингр.1, в верхний сплиттер)
  --   inputs[2] = { x = c_split_L+2, y = 0 }  (ингр.2, в подземку)
  --
  -- Для 3-4 ингр. (width = 2*W+9):
  --   inputs[1] = { x = 2, y = 0 }            (ингр.2 — на левый сплиттер)
  --   inputs[2] = { x = 4, y = 0 }            (ингр.1 — в подземку левой шапки)
  --   inputs[3] = { x = 6, y = 2 }            (ингр.4 — на правый сплиттер)
  --   inputs[4] = { x = 8, y = 2 }            (ингр.3 — в подземку правой шапки)
  --
  -- Координата выхода продукта — нижний ряд центральной ленты:
  --   product_out = { x = c_belt_C, y = body_start + body_h - 1 + 1 }
  --   (на y сразу под последней клеткой центральной ленты)
  --
  local meta = {
    offset_x   = offset_x,
    offset_y   = offset_y,
    width      = width,
    height     = body_start + body_h,
    ing_count  = ing_count,
    ingredients = get_ingredient_names(recipe_node),
    products   = {},
    inputs     = {},
    product_out = nil,
  }

  -- Список продуктов
  if recipe_node.products then
    for _, p in pairs(recipe_node.products) do
      if p.type ~= "fluid" and p.name then
        meta.products[#meta.products + 1] = p.name
      end
    end
  end
  if #meta.products == 0 and recipe_node.name then
    local p = prototypes.recipe[recipe_node.name]
    if p then
      for _, prod in pairs(p.products) do
        if prod.type ~= "fluid" then
          meta.products[#meta.products + 1] = prod.name
        end
      end
    end
  end

  -- Координаты входов и выхода (с учётом сдвига при наличии жидкости)
  if ing_count <= 2 then
    local c_split_L = math.floor((solid_width - 1) / 2) - 1
    if ing_count >= 1 then
      meta.inputs[1] = { x = solid_offset_x + c_split_L,     y = offset_y + 0, ingredient = meta.ingredients[1] }
    end
    if ing_count >= 2 then
      meta.inputs[2] = { x = solid_offset_x + c_split_L + 2, y = offset_y + 0, ingredient = meta.ingredients[2] }
    end
    meta.product_out = {
      x = solid_offset_x + (W + 3),
      y = offset_y + (body_start + body_h)
    }
  else
    local c_split_L_L = 2
    local c_split_R_L = solid_width - 3 - W - 3
    if ing_count >= 1 then
      meta.inputs[1] = { x = solid_offset_x + c_split_L_L,     y = offset_y + 0, ingredient = meta.ingredients[1] }
    end
    if ing_count >= 2 then
      meta.inputs[2] = { x = solid_offset_x + c_split_L_L + 2, y = offset_y + 0, ingredient = meta.ingredients[2] }
    end
    if ing_count >= 3 then
      meta.inputs[3] = { x = solid_offset_x + c_split_R_L,     y = offset_y + 2, ingredient = meta.ingredients[3] }
    end
    if ing_count >= 4 then
      meta.inputs[4] = { x = solid_offset_x + c_split_R_L + 2, y = offset_y + 2, ingredient = meta.ingredients[4] }
    end
    -- Синхронизируем product_out с реальной позицией центральной ленты в build_body:
    -- c_belt_C = floor((c_ins_out_L + c_ins_out_R) / 2)
    -- где c_ins_out_L = 3 + W, c_ins_out_R = (solid_width - 3 - W) - 1 = solid_width - 4 - W
    local _ins_out_L = 3 + W
    local _ins_out_R = solid_width - 4 - W
    local _belt_C    = math.floor((_ins_out_L + _ins_out_R) / 2)
    if _belt_C == _ins_out_L or _belt_C == _ins_out_R then
      _belt_C = _ins_out_L + 1
    end
    meta.product_out = {
      x = solid_offset_x + _belt_C,
      y = offset_y + body_start + body_h - (beacon_bay and 1 or 0),
      direction = beacon_bay and defines.direction.south or nil
    }
  end

  return en, body_start + body_h, meta
end

-- ── Обход дерева Helmod ──────────────────────────────────────
-- Собирает рецепты из модели. Если target_block_id задан — только из поддерева
-- блока с этим id (для построения отдельного блока, а не всей линии).
local function collect_recipes(node, result, parent_block_id, target_block_id, inside_target)
  result = result or {}
  if not node then return result end
  if node.class == "Model" then
    local root = node.block_root
    collect_recipes(root, result, root and root.id, target_block_id, inside_target)
  elseif node.class == "Block" then
    local bid = node.id or parent_block_id
    -- Если ищем конкретный блок и это он — дальше собираем всё его поддерево.
    local now_inside = inside_target or (target_block_id == nil) or (bid == target_block_id)
    if node.children then
      local keys={}
      for key in pairs(node.children) do keys[#keys+1]=key end
      table.sort(keys,function(a,b)
        local x=tonumber(node.children[a].index) or math.huge
        local y=tonumber(node.children[b].index) or math.huge
        if x~=y then return x<y end
        return tostring(a)<tostring(b)
      end)
      for _,key in ipairs(keys) do
        collect_recipes(node.children[key], result, bid, target_block_id, now_inside)
      end
    end
  elseif node.class == "Recipe" then
    if inside_target or target_block_id == nil then
      local ok, enr = pcall(remote.call, "helmod_interface", "get_recipe", node)
      if ok and enr then
        node.products    = enr.products
        node.ingredients = enr.ingredients
      end
      node.parent_block_id = parent_block_id
      result[#result+1] = node
    end
  end
  return result
end

-- Собирает список под-блоков модели (для GUI: возможность построить блок отдельно).
-- Возвращает массив { id, name, sprite, recipe_count }.
local function collect_blocks(model)
  local blocks = {}
  local function sprite_for_name(nm)
    if not nm then return nil end
    if prototypes.recipe and prototypes.recipe[nm] then return "recipe/" .. nm
    elseif prototypes.item and prototypes.item[nm] then return "item/" .. nm
    elseif prototypes.fluid and prototypes.fluid[nm] then return "fluid/" .. nm
    elseif prototypes.entity and prototypes.entity[nm] then return "entity/" .. nm end
    return nil
  end
  local function count_recipes(node)
    local n = 0
    if not node or not node.children then return 0 end
    for _, c in pairs(node.children) do
      if c.class == "Recipe" then n = n + 1
      elseif c.class == "Block" then n = n + count_recipes(c) end
    end
    return n
  end
  local function first_recipe_name(node)
    if not node or not node.children then return nil end
    for _, c in pairs(node.children) do
      if c.class == "Recipe" and c.name then return c.name end
    end
    for _, c in pairs(node.children) do
      if c.class == "Block" then
        local nm = first_recipe_name(c)
        if nm then return nm end
      end
    end
    return nil
  end
  local function walk(node, is_root)
    if not node then return end
    if node.class == "Model" then
      walk(node.block_root, true)
    elseif node.class == "Block" then
      -- Сам корневой блок модели = "вся линия" (показан отдельной зелёной кнопкой),
      -- поэтому его в список под-блоков НЕ добавляем — только его дочерние блоки.
      if not is_root then
        local rc = count_recipes(node)
        if rc > 0 then
          local nm = first_recipe_name(node)
          blocks[#blocks+1] = {
            id = node.id,
            name = node.name and not tostring(node.name):match('^block_%d+$') and node.name or nm or tostring(node.id),
            sprite = sprite_for_name(nm),
            recipe_count = rc,
          }
        end
      end
      if node.children then
        for _, c in pairs(node.children) do
          if c.class == "Block" then walk(c, false) end
        end
      end
    end
  end
  walk(model, false)
  return blocks
end

-- ── Сборка чертежа ───────────────────────────────────────────
-- Вертикальный зазор между блоками. Увеличен с 3 до 6, чтобы маршруты подключения
-- producer→магистраль помещались в зазор между блоками, не конкурируя за клетки.
local BLOCK_GAP = 6

-- ── Соединение блоков конвейерами ─────────────────────────────
--
-- Принцип:
-- 1) Собираем все блоки с их метаданными (входы и выход продукта)
-- 2) Для каждого блока N+1 (вниз по списку) проходим его входы (ingredients)
-- 3) Для каждого ингредиента ищем какой блок выше его производит
-- 4) Если найден: считаем сколько блоков-потребителей у этого продукта
--    - 1 потребитель: простая прямая лента от выхода к входу
--    - 2+ потребителей: сплиттер делит ленту, отводя в каждое место
--
-- Для простоты v0.7.0: соединяем только если 1 потребитель.
-- Для нескольких потребителей одного продукта — пока не делаем сплиттер.
--


-- ── Соединение блоков через BFS-pathfinding ─────────────────────
-- Алгоритм:
-- 1. Все блоки помечаются как "сплошные" занятые области (нельзя пересекать).
-- 2. Для каждого продукта в порядке (по 1 продукту за раз):
--    - Собираем все точки потребителей.
--    - Для каждой пары (выход, вход) ищем кратчайший путь BFS через свободные клетки.
--    - Прокладываем этот путь (ленты с правильными направлениями на поворотах).
--    - Помечаем клетки пути как занятые маршрутом.
-- 3. Для нескольких потребителей одного продукта вставляем сплиттер 1×2 в одной из
--    точек пути, и продолжаем 2 пути от его выходов к разным потребителям.

-- ── Соединение блоков по детерминированным правилам ──────────────
-- Правила маршрутизации:
-- 1. Каждая лента стартует с клетки выхода продукта (направление ↓).
-- 2. Делает 1 поворот в сторону (влево или вправо) — выбирается так чтобы быть
--    подальше от других маршрутов и ближе к блоку-потребителю.
-- 3. Идёт по выбранной горизонтали без поворотов до крайней клетки производителя
--    + 1 клетка отступа.
-- 4. Поворот вниз, идёт до Y входа блока-потребителя.
-- 5. Поворот к входу, заходит на вход.
--
-- Для нескольких лент к одному блоку-потребителю каждая следующая поворачивает
-- вниз на 1 клетку раньше предыдущей (отступ).
--
-- Если у блока 4 входа — 2 ленты слева, 2 справа.

generation_work.register('routing-occupancy-step',function(args,state)
  if not state.result then state.result={occupied={},cell_dir={},cell_kind={},ug_names={},hard_block={},splitter_owner={},surface_names={[args.belt]=true},max_block_x=-math.huge};state.properties={};state.index=1 end
  local out=state.result
  local occupied,cell_dir,cell_kind,hard_block,splitter_owner,surface_names=out.occupied,out.cell_dir,out.cell_kind,out.hard_block,out.splitter_owner,out.surface_names
  out.ug_names=out.ug_names or {}
  local max_block_x=out.max_block_x;local properties=state.properties
  local dir_e,dir_w=4,12
  local function key(x,y)return x..','..y end
  local function mark(x,y,kind)occupied[key(x,y)]=kind end
  while state.index<=#args.entities do
    if not generation_work.consume(4) then out.max_block_x=max_block_x;return false end
    local e=args.entities[state.index];state.index=state.index+1
    local px = e.position.x
    local py = e.position.y
    local proto=properties[e.name]
    if proto==nil then
      local p=prototypes.entity[e.name];proto=p and {tile_width=p.tile_width,tile_height=p.tile_height,type=p.type} or false;properties[e.name]=proto
    end
    local w = (proto and proto.tile_width)  or 1
    local h = (proto and proto.tile_height) or 1
    local tlx = math.floor(px - w / 2 + 0.001)
    local tly = math.floor(py - h / 2 + 0.001)
    if e.direction == dir_e or e.direction == dir_w then w,h=h,w end
    tlx=math.floor(px-w/2+0.001)
    tly=math.floor(py-h/2+0.001)
    local is_belt = proto and proto.type == "transport-belt"
    if is_belt then surface_names[e.name]=true end
    local is_ug = proto and proto.type == "underground-belt"
    local is_splitter = proto and proto.type == "splitter"
    local is_belt_like = is_belt or is_ug or is_splitter
    local ck = nil
    if is_belt then ck = "belt"
    elseif is_ug then ck = (e.type == "input") and "ug_in" or "ug_out"
    elseif is_splitter then ck = "splitter" end
    for dx = 0, w - 1 do
      for dy = 0, h - 1 do
        mark(tlx + dx, tly + dy, "block")
        max_block_x=math.max(max_block_x,tlx+dx)
        if not is_belt then hard_block[key(tlx+dx,tly+dy)]=true end
        if is_splitter then splitter_owner[key(tlx+dx,tly+dy)]=e end
        if is_belt_like then
          cell_dir[key(tlx + dx, tly + dy)] = e.direction or 0
          if ck then cell_kind[key(tlx + dx, tly + dy)] = ck end
          if is_ug then out.ug_names[key(tlx+dx,tly+dy)]=e.name end
        end
      end
    end
  end
  if args.prepared then
    for _,block in ipairs(args.blocks) do
      if block.product_out then
        mark(block.product_out.x,block.product_out.y,'io')
        for _,p in pairs(block.product_outs or {}) do mark(p.x,p.y,'io') end
        for _,p in ipairs(block.output_ports or {}) do mark(p.x,p.y,'io') end
      end
      for _,p in ipairs(block.inputs or {}) do mark(p.x,p.y,'io') end
    end
    for _,block in ipairs(args.blocks) do for _,p in ipairs(block.junction_guards or {}) do mark(p.x,p.y,'reserved') end end
    for _,port in ipairs(args.external_plan or {}) do if port.type=='item' then mark(port.input.x,port.input.y,'io') end end
  end
  out.max_block_x=max_block_x;return true,out
end)
generation_work.register('surface-index',function(args,state)
 state.index=state.index or 1;state.result=state.result or {};if args.capture_entities then state.entities=state.entities or {} end
 while state.index<=#args.entities do
  if not generation_work.consume() then return false end
  local i=state.index;local e=args.entities[i];state.index=i+1;if state.entities then state.entities[i]=e end
  if args.names[e.name] then
   local k=math.floor(e.position.x)..','..math.floor(e.position.y)
   state.result[k]=state.result[k] or {};state.result[k][#state.result[k]+1]=i
  end
 end
 return true,state.result,state.entities
end)
local function connect_blocks(blocks_meta, settings, en, list, routing_bundle)
  if settings.output_consumers and not settings.external_only and not settings.outputs_only then
    local joined={};for _,b in ipairs(blocks_meta) do joined[#joined+1]=b end
    for _,b in ipairs(settings.output_consumers) do joined[#joined+1]=b end
    blocks_meta=joined
  end
  -- A shared producer route can carry several slower consumer inputs.
  -- Use the faster selected tier so it does not throttle the producer output.
  local belt_in=settings.belt_in or "transport-belt"
  if belt_throughput(settings.belt_out or "transport-belt")>belt_throughput(belt_in) then
    belt_in=settings.belt_out
  end
  local splitter = to_splitter(belt_in)
  local ug_belt  = to_underground(belt_in)
  if not entity_exists(belt_in)  then belt_in  = "transport-belt" end
  if not entity_exists(splitter) then splitter = "splitter" end
  if not entity_exists(ug_belt)  then ug_belt  = "underground-belt" end

  local dir_n = defines.direction.north
  local dir_s = defines.direction.south
  local dir_e = defines.direction.east
  local dir_w = defines.direction.west

  local max_ug_dist = get_underground_max_distance(belt_in)
  local block_cells,port_access,machine_cells,port_owners,cluster_cells,owner_clusters,cluster_bounds=block_boundaries.build(blocks_meta)
  generation_work.section_boundary()
  local route_extent
  for _,b in pairs(cluster_bounds) do
    if not route_extent then route_extent={left=b.left,top=b.top,right=b.right,bottom=b.bottom}
    else route_extent.left=math.min(route_extent.left,b.left);route_extent.top=math.min(route_extent.top,b.top);route_extent.right=math.max(route_extent.right,b.right);route_extent.bottom=math.max(route_extent.bottom,b.bottom) end
  end
  local route_source_owner,route_target_owner,route_source_port_key,route_target_port_key,route_is_export

  -- ── Учёт занятых клеток ──
  -- "block" — занятая блоком (нельзя пересекать)
  -- "route" — занятая соединительной лентой (можно нырнуть подземкой)
  -- cell_dir — направление ленты, cell_kind — тип ("belt", "ug_in", "ug_out", "splitter")
  local occupied = {}
  local cell_dir = {}
  local cell_kind = {}
  local ug_names = {}
  local hard_block = {}
  local splitter_owner={}
  local surface_names={[belt_in]=true}
  local reserved_taps = {}
  local routing_producers = true
  local LANE_SPACING = 3 -- one bus cell, a splitter outlet, and a crossing gap
  local max_block_x=-math.huge
  local function key(cx, cy) return cx .. "," .. cy end
  local function mark(cx, cy, kind) occupied[key(cx, cy)] = kind end
  local function mark_belt(cx, cy, kind, d, ck)
    occupied[key(cx, cy)] = kind
    cell_dir[key(cx, cy)] = d
    if ck then cell_kind[key(cx, cy)] = ck end
    local k=key(cx,cy)
    if ck=='ug_in' or ck=='ug_out' then ug_names[k]=ug_names[k] or ug_belt
    elseif ck then ug_names[k]=nil end
  end
  local function get_occ(cx, cy) return occupied[key(cx, cy)] end
  local function get_cell_dir(cx, cy) return cell_dir[key(cx, cy)] end
  local function get_cell_kind(cx, cy) return cell_kind[key(cx, cy)] end

  -- Заполняем карту блоков
  -- Route replay starts from the same stage input. Cache the prototype scan,
  -- then use a private copy because committing a route changes these maps.
  -- Task and input-port checkpoints create private maps before committing
  -- any route. Their initial routing seed can therefore stay immutable.
  local readonly_seed=not settings.outputs_only and (settings.external_only or routing_bundle~=nil)
  local initial_occupancy=generation_work.operation('routing-occupancy-step',nil,
    {entities=list,belt=belt_in,blocks=blocks_meta,prepared=readonly_seed,external_plan=settings.external_only and settings.external_plan or nil},readonly_seed)
  occupied,cell_dir,cell_kind=initial_occupancy.occupied,initial_occupancy.cell_dir,initial_occupancy.cell_kind
  ug_names=initial_occupancy.ug_names or {}
  hard_block,splitter_owner,surface_names,max_block_x=initial_occupancy.hard_block,initial_occupancy.splitter_owner,initial_occupancy.surface_names,initial_occupancy.max_block_x
  generation_work.section_boundary()

  -- Точки входа/выхода — IO (доступны для финиша/старта пути)
  if not readonly_seed then
  for _, block in ipairs(blocks_meta) do
    if block.product_out then
      mark(block.product_out.x, block.product_out.y, "io")
      for _,p in pairs(block.product_outs or {}) do mark(p.x,p.y,"io") end
      for _,p in ipairs(block.output_ports or {}) do mark(p.x,p.y,"io") end
    end
    for _, inp in ipairs(block.inputs or {}) do
      mark(inp.x, inp.y, "io")
    end
  end
  end

  -- ── Карта продукт → производители (LIST!) и потребители ──
  local producers_for = {}
  for _, block in ipairs(blocks_meta) do
    for _, prod in ipairs(block.products or {}) do
      if not producers_for[prod] then producers_for[prod] = {} end
      for _,port in ipairs(resources.ports(block,prod)) do
        if not block.output_ports then table.insert(producers_for[prod],block) else
          local view={};for k,v in pairs(block) do view[k]=v end
          view._owner=block;view.product_out=port;view.output_ports=nil;view.product_outs=nil
          view.recipe_node={};for k,v in pairs(block.recipe_node) do view.recipe_node[k]=v end
          view.recipe_node.products={}
          for _,v in ipairs(block.recipe_node.products or {}) do local q={};for k,x in pairs(v) do q[k]=x end
            if type(q.count)=='number' then q.count=q.count*(port.share or 1) end
            if type(q.amount)=='number' then q.amount=q.amount*(port.share or 1) end
            view.recipe_node.products[#view.recipe_node.products+1]=q
          end
          table.insert(producers_for[prod],view)
        end
      end
    end
  end
  -- Совместимость: producer_for[item] = первый producer
  local producer_for = {}
  for item, plist in pairs(producers_for) do
    producer_for[item] = plist[1]
  end
  -- Лог producers_for деталей (какие блоки производят каждый продукт)
  if _diag_log_buffer or _diag_player then
    for item, plist in pairs(producers_for) do
      if #plist > 1 then
        local lst = ""
        for _, b in ipairs(plist) do
          lst = lst .. string.format(" block(y=%d..%d,p_out=%s)",
            b.offset_y, b.offset_y + b.height - 1,
            b.product_out and string.format("(%d,%d)", b.product_out.x, b.product_out.y) or "nil")
        end
        _diag_log(string.format("[BFH-prod] '%s' (%d producers):%s", item, #plist, lst))
      end
    end
  end

  local consumers_for = {}
  for i = 1, #blocks_meta do
    local block = blocks_meta[i]
    for _, inp in ipairs(block.inputs or {}) do
      local ing = inp.ingredient
      if ing and not inp.array_local and producer_for[ing] and (producer_for[ing]._owner or producer_for[ing]) ~= block and (not settings.outputs_only or block.is_external_output) then
        if not consumers_for[ing] then consumers_for[ing] = {} end
        -- Расчёт throughput consumer'а в items/sec из Helmod-модели.
        -- Если данных нет — берём 0 (consumer возьмёт сколько успеет с любой ленты).
        local need_ips = 0
        local rn = block.recipe_node
        if inp.graph_rate then need_ips=inp.graph_rate
        elseif rn and rn.ingredients then
          for _, ri in pairs(rn.ingredients) do
            if ri and ri.name == ing then
              local ok, v = pcall(get_flow_per_sec, ri, rn)
              if ok and type(v) == "number" then need_ips = v end
              break
            end
          end
        end
        if not settings.external_only and not settings.outputs_only then inp.planned_rate=need_ips;inp.connected_rate=0 end
        table.insert(consumers_for[ing], { block = block, input = inp, need_ips = need_ips })
      end
    end
  end

  local function cell_info(x, y)
    local k = key(x, y)
    local kind = cell_kind[k]
    return cell_dir[k], kind, (kind == "ug_in" or kind == "ug_out") and (ug_names[k] or ug_belt) or nil
  end
  local surface_lookup,initial_surface_entities,surface_base={},{},{}
  local surface_version,indexed_version=0,0
  local latest_surface=surface_base
  local function build_surface_indices(capture_entities)
    return generation_work.operation('surface-index',nil,{entities=list,names=surface_names,capture_entities=capture_entities},true)
  end
  local function rebuild_surface_lookup(indices,immutable_entities)
    surface_lookup={};initial_surface_entities=immutable_entities
    if not initial_surface_entities then
      initial_surface_entities={};for i,e in ipairs(list) do initial_surface_entities[i]=e end
    end
    surface_base=indices or build_surface_indices()
    latest_surface=surface_base;surface_version=0;indexed_version=0
  end
  local function surface_indices()
    if indexed_version~=surface_version then
      latest_surface=build_surface_indices();indexed_version=surface_version
    end
    return latest_surface
  end
  local function surface_entries(k)
    local entries=surface_lookup[k]
    if entries==nil then
      entries={}
      for _,i in ipairs(surface_base[k] or {}) do entries[#entries+1]={entity=initial_surface_entities[i],index=i} end
      surface_lookup[k]=entries
    elseif entries==false then return {} end
    return entries
  end
  local function remember_surface(e,index)
    if not surface_names[e.name] then return end
    local k=key(math.floor(e.position.x),math.floor(e.position.y))
    if surface_lookup[k]==false then surface_lookup[k]={} end
    local entries=surface_entries(k);entries[#entries+1]={entity=e,index=index}
    surface_version=surface_version+1
  end
  local append_entity_cell=add_entity_cell
  local function add_entity_cell(...)
    local next_en=append_entity_cell(...)
    remember_surface(list[#list],#list)
    return next_en
  end
  local function find_surface(x,y)
    local found={};local entries=surface_entries(key(x,y));local upper=#list
    for j=#entries,1,-1 do local entry=entries[j]
      for i=math.min(entry.index,upper),1,-1 do if list[i]==entry.entity then
        upper=i-1;found[#found+1]={index=i,entity=entry.entity};break
      end end
    end
    return found
  end
  local function remove_surface_belt(x,y)
    local found=find_surface(x,y)
    for _,entry in ipairs(found) do table.remove(list,entry.index) end
    surface_lookup[key(x,y)]=false
    if #found>0 then surface_version=surface_version+1 end
  end
  if not readonly_seed then
  for _,b in ipairs(blocks_meta) do for _,p in ipairs(b.junction_guards or {}) do mark(p.x,p.y,'reserved') end end
  end
  local endpoint_reservations={}
  local endpoint_vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  local no_reservations={} -- immutable fallback for reservation lookups
  local function reserve_owner(k,owner)
    local owners={};for name,value in pairs(endpoint_reservations[k] or no_reservations) do owners[name]=value end
    owners[owner]=true;endpoint_reservations[k]=owners
  end
  local function release_owner(owner)
    for k,owners in pairs(endpoint_reservations) do if owners[owner] then
      local remaining={};for name,value in pairs(owners) do if name~=owner then remaining[name]=value end end
      endpoint_reservations[k]=remaining
    end end
  end
  local function reserve_endpoint(p,sign,apron)
    if not p then return end
    local v=endpoint_vectors[p.direction or get_cell_dir(p.x,p.y) or dir_s]
    local owner=key(p.x,p.y)
    -- Keep the whole declared approach through an irregular header open.
    -- Reserving only two cells allowed another input route to fence off the
    -- third cell, leaving a geometrically reachable but unusable inlet pocket.
    for k in pairs(port_access[owner] or {}) do
      reserve_owner(k,owner)
    end
    for step=0,3 do for side=-(apron and step>0 and 1 or 0),(apron and step>0 and 1 or 0) do
      local k=key(p.x+v[1]*step*sign+v[2]*side,p.y+v[2]*step*sign-v[1]*side)
      reserve_owner(k,owner)
    end end
    -- Stacked ingredient headers may block the straight approach. Preserve
    -- one surface turn beside the inlet; a tunnel exit cannot turn in place.
    if sign<0 then for _,side in ipairs({-1,1}) do
      local x,y=p.x+v[2]*side,p.y-v[1]*side;local k=key(x,y)
      if get_occ(x,y)==nil and not next(endpoint_reservations[k] or no_reservations) then
        reserve_owner(k,owner);break
      end
    end end
  end
  local initial_endpoints=generation_work.cached('routing-endpoints',function()
  for _,b in ipairs(blocks_meta) do
    reserve_endpoint(b.product_out,1)
    for _,p in ipairs(b.output_ports or {}) do reserve_endpoint(p,1) end
    for _,p in pairs(b.product_outs or {}) do reserve_endpoint(p,1) end
    for _,p in ipairs(b.inputs or {}) do if not p.array_local then reserve_endpoint(p,-1,b.is_external_output) end end
  end
  -- Spare turning cells must not steal another declared inlet or outlet.
  local function reserve_turn(p)
    if not p then return end
    local v=endpoint_vectors[p.direction or get_cell_dir(p.x,p.y) or dir_s];local owner=key(p.x,p.y)
    for step=1,2 do for _,side in ipairs({-1,1}) do
      local k=key(p.x+v[1]*step+v[2]*side,p.y+v[2]*step-v[1]*side)
      local free=occupied[k]==nil and block_cells[k]==nil and not reserved_taps[k]
      for other in pairs(endpoint_reservations[k] or {}) do if other~=owner then free=false end end
      if free then endpoint_reservations[k]=endpoint_reservations[k] or {};endpoint_reservations[k][owner]=true end
    end end
  end
  for _,b in ipairs(blocks_meta) do
    reserve_turn(b.product_out)
    for _,p in ipairs(b.output_ports or {}) do reserve_turn(p) end
    for _,p in pairs(b.product_outs or {}) do reserve_turn(p) end
  end
  -- Export ports must remain extendable after the other routes are built.
  -- Their downstream clearance is permanent, unlike an owned route approach.
  for _,b in ipairs(settings.output_consumers or {}) do local p=b.export
    if p then local v=endpoint_vectors[p.direction or dir_e]
      for step=1,3 do for side=-1,1 do
        local k=key(p.x+v[1]*step+v[2]*side,p.y+v[2]*step-v[1]*side)
        endpoint_reservations[k]=endpoint_reservations[k] or {}
        endpoint_reservations[k]['external-clearance']=true
      end end
    end
  end
  return endpoint_reservations
  end,true)
  endpoint_reservations={};for k,owners in pairs(initial_endpoints) do endpoint_reservations[k]=owners end
  generation_work.section_boundary()
  local initial_surface,initial_entities=generation_work.cached('surface-indices',function()return build_surface_indices(true)end,true)
  rebuild_surface_lookup(initial_surface,initial_entities)
  local cluster_lanes=generation_work.cached('routing-cluster-lanes',function()
    local materials,lanes={},{}
    for _,block in ipairs(blocks_meta) do local cluster=owner_clusters[block.route_owner]
      if cluster then
        materials[cluster]=materials[cluster] or {}
        for _,port in ipairs(block.inputs or {}) do if not port.array_local then materials[cluster][port.ingredient]=true end end
      end
    end
    for cluster,names in pairs(materials) do local count=0;for _ in pairs(names) do count=count+1 end;lanes[cluster]=math.max(1,count) end
    return lanes
  end,true)
  local last_plan
  local route_deep_search=true
  local function route_bfs(sx, sy, tx, ty, label, ci, final_dir, no_up, start_dir, no_east,preserve_merges)
    local plan,reason=generation_work.cached('planned-route',function()
    final_dir = final_dir or dir_s
    if hard_block[key(sx,sy)] or hard_block[key(tx,ty)] then
      _diag_log("[BFH-route] REJECT " .. (label or "?") .. ": obstructed endpoint")
      return nil,"obstructed endpoint"
    end
    local source_key,target_key=key(sx,sy),key(tx,ty)
    local options={
      sx=sx, sy=sy, tx=tx, ty=ty,
      start_dir=start_dir or dir_s, final_dir=final_dir,
      heuristic_weight=settings.layout_search=='thorough' and 1 or 4,
      avoid_empty_tunnels=true,
      shallow=not route_deep_search,
      start_tunnel=cell_kind[source_key]==nil or cell_kind[source_key]=='belt',
      no_up=no_up, no_east=no_east,
      context={layout_bounds=route_extent,occupied=occupied,endpoint_reservations=endpoint_reservations,block_cells=block_cells,port_access=port_access,cluster_cells=cluster_cells,source_cluster=owner_clusters[route_source_owner or port_owners[source_key]],target_cluster=owner_clusters[route_target_owner or port_owners[target_key]],machine_cells=machine_cells,source_owner=route_source_owner or port_owners[source_key],target_owner=route_target_owner or port_owners[target_key],
        source_key=source_key,target_key=target_key,source_reservation=route_source_port_key,target_reservation=route_target_port_key,routing_producers=routing_producers,
        reserved_taps=reserved_taps,cell_dir=cell_dir,cell_kind=cell_kind,ug_names=ug_names,ug_name=ug_belt},
      target_free=get_occ(tx,ty)==nil or get_occ(tx,ty)=="io" or get_occ(tx,ty)=="reserved",
      max_states=settings.layout_search~='thorough' and (not route_deep_search and 3000 or (settings.external_only and 24000 or (route_is_export and 12000 or 3000))) or nil,
      max_distance=max_ug_dist, ug_name=ug_belt, min_x=settings.routing_min_x, max_x=settings.routing_max_x, entry_x=settings.external_only and sx or nil,
    }
    local sc=options.context.source_cluster;local tc=options.context.target_cluster
    if sc and sc==tc and cluster_bounds[sc] then local b=cluster_bounds[sc]
      local lanes=cluster_lanes[sc] or 1
      options.min_x=math.max(options.min_x or -math.huge,b.left-lanes);options.max_x=math.min(options.max_x or math.huge,b.right+lanes)
      options.min_y=b.top-lanes;options.max_y=b.bottom+lanes
    end
    local plan,reason=router.plan(options)
    if not plan and route_deep_search and reason=='search-limit' and not settings.external_only and not route_is_export and settings.layout_search~='thorough' then
      options.max_states=24000;plan,reason=router.plan(options)
      if not plan and reason=='search-limit' then
        options.heuristic_weight=1;plan,reason=router.plan(options)
      end
    end
    if not plan and settings.external_only and reason~='layout-search-limit' and not (reason and reason:find('^blocked')) then
      options.margin=48;options.max_states=settings.layout_search~='thorough' and 3000 or 120000
      plan,reason=router.plan(options)
    end
    return plan,reason
    end,true)
    if not plan then
      _diag_log(string.format("[BFH-route] REJECT %s (%d,%d)->(%d,%d): %s",
        label or "?",sx,sy,tx,ty,reason))
      return false
    end
    last_plan=plan
    -- A completed route is immutable. Replay its records and keys, rather than
    -- allocating the same entities again before the next unfinished search.
    local committed=generation_work.cached('route-commit',function()
      local result={start=en,en=en,entities={},keys={}}
      for i,cell in ipairs(plan) do
        local underground=cell.kind=='ug_in' or cell.kind=='ug_out'
        local entity={entity_number=result.en,name=underground and ug_belt or belt_in,
          position={x=cell.x+.5,y=cell.y+.5},direction=cell.d or dir_n}
        if underground then entity.type=cell.kind=='ug_in' and 'input' or 'output' end
        result.entities[i]=entity;result.keys[i]=key(cell.x,cell.y);result.en=result.en+1
      end
      return result
    end,true)
    assert(en==committed.start,'route commit replay diverged')
    -- Only the explicitly selected source and destination may replace block belts.
    remove_surface_belt(sx,sy)
    remove_surface_belt(tx,ty)
    for i,entity in ipairs(committed.entities) do
      list[#list+1]=entity;remember_surface(entity,#list)
      local k=committed.keys[i];occupied[k]='route';cell_dir[k]=plan[i].d;if plan[i].kind then cell_kind[k]=plan[i].kind end
      ug_names[k]=(plan[i].kind=='ug_in' or plan[i].kind=='ug_out') and entity.name or nil
    end
    en=committed.en
    _diag_log(string.format("[BFH-route] OK %s: %d entities",label or "?",#plan))
    return true
  end

  local function snapshot()
    local surface=surface_indices()
    local result=generation_work.shallow_snapshot({list=list,occ=occupied,dir=cell_dir,kind=cell_kind,tiers=ug_names,guards=endpoint_reservations,en=en})
    -- The surface index is immutable and is rebuilt after every edit.
    local t={};for k,v in pairs(result) do t[k]=v end;t.surface=surface
    return t
  end

  local function restore(t)
    local restored=generation_work.fork('restore-route-state',
      {occ=t.occ,dir=t.dir,kind=t.kind,tiers=t.tiers,guards=t.guards,en=t.en})
    for i=#list,1,-1 do list[i]=nil end
    for i,e in ipairs(t.list) do list[i]=e end
    occupied,cell_dir,cell_kind,endpoint_reservations,en=restored.occ,restored.dir,restored.kind,restored.guards,restored.en
    ug_names=restored.tiers or {}
    rebuild_surface_lookup(t.surface,t.list)
  end

  -- A failed route never edits entities. A tentative splitter only replaces
  -- one surface cell and adds one entity: retain those changes, not the factory.
  local function trial_snapshot(x,y,xx,yy)
    local saved={en=en,length=#list,removed={},cells={},surface_key=key(x,y),surface_version=surface_version}
    for _,p in ipairs({{x,y},{xx,yy}}) do
      local k=key(p[1],p[2]);saved.cells[#saved.cells+1]={key=k,occ=occupied[k],dir=cell_dir[k],kind=cell_kind[k],tier=ug_names[k]}
    end
    for _,entry in ipairs(find_surface(x,y)) do saved.removed[#saved.removed+1]=entry end
    saved.surface_entry=surface_lookup[saved.surface_key]
    return saved
  end
  local function restore_trial(saved)
    if not saved then return end
    local retained=saved.length-#saved.removed
    while #list>retained do list[#list]=nil end
    for i=#saved.removed,1,-1 do local r=saved.removed[i];table.insert(list,r.index,r.entity) end
    for _,c in ipairs(saved.cells) do occupied[c.key]=c.occ;cell_dir[c.key]=c.dir;cell_kind[c.key]=c.kind;ug_names[c.key]=c.tier end
    en=saved.en
    -- Failed searches add no belts. Only the tentative splitter cell was
    -- removed, so undo its lookup entry instead of reindexing the factory.
    -- Lookup indices remain upper bounds across nested rollbacks.
    surface_lookup[saved.surface_key]=saved.surface_entry
    surface_version=saved.surface_version;indexed_version=-1
  end

  if settings.outputs_only then
    routing_producers=false
    local links=settings.output_links or {}
    for _,link in ipairs(links) do
      mark(link.source.x,link.source.y,'io');mark(link.target.x,link.target.y,'io')
      reserve_endpoint(link.source,1);reserve_endpoint(link.target,-1)
    end
    local near={};for i,link in ipairs(links) do near[i]=link end
    table.sort(near,function(a,b)
      local ad=math.abs(a.source.x-a.target.x)+math.abs(a.source.y-a.target.y)
      local bd=math.abs(b.source.x-b.target.x)+math.abs(b.source.y-b.target.y)
      if ad~=bd then return ad<bd end
      if a.source.y~=b.source.y then return a.source.y<b.source.y end
      return a.source.x<b.source.x
    end)
    local reverse={};for i=#links,1,-1 do reverse[#reverse+1]=links[i] end
    local base=generation_work.cached('output-route-base',snapshot,true);local best,best_failures
    for order_index,order in ipairs({links,near,reverse}) do
      if order_index>1 then restore(base) end
      local success={}
      local function connect(link)
        local src,target=link.source,link.target
        if route_bfs(src.x,src.y,target.x,target.y,'output '..link.name,1,target.direction or dir_e,false,get_cell_dir(src.x,src.y) or src.direction or dir_s) then
          success[link]=true
          local source_owner,target_owner=key(src.x,src.y),key(target.x,target.y)
          for k,owners in pairs(endpoint_reservations) do
            if owners[source_owner] or owners[target_owner] then
              local updated={};for owner,value in pairs(owners) do if owner~=source_owner and owner~=target_owner then updated[owner]=value end end
              endpoint_reservations[k]=updated
            end
          end
          return true
        end
      end
      for _,link in ipairs(order) do connect(link) end
      for pass=1,2 do
        local progress=false
        for _,link in ipairs(order) do if not success[link] and connect(link) then progress=true end end
        if not progress then break end
      end
      local failures=0;for _,link in ipairs(order) do if not success[link] then failures=failures+1 end end
      -- A successful current order already is the desired final geometry.
      if failures==0 then return en,0 end
      if not best_failures or failures<best_failures then best=snapshot();best_failures=failures end
    end
    restore(best);return en,best_failures
  end

  if settings.external_only then
    routing_producers=false
    local ports={}
    for _,port in ipairs(settings.external_plan or {}) do if port.type=='item' then
      ports[#ports+1]=port;if not readonly_seed then mark(port.input.x,port.input.y,'io') end;reserve_endpoint(port,1);reserve_endpoint(port.input,-1)
    end end
    local orders={}
    local far={};for i,p in ipairs(ports) do far[i]=p end
    table.sort(far,function(a,b)
      local da=math.abs(a.x-a.input.x)+math.abs(a.y-a.input.y);local db=math.abs(b.x-b.input.x)+math.abs(b.y-b.input.y)
      if da~=db then return da>db end
      if a.y~=b.y then return a.y>b.y end
      return a.x<b.x
    end)
    local near={};for i=#far,1,-1 do near[#near+1]=far[i] end
    local constrained={};for i,p in ipairs(ports) do constrained[i]=p end
    table.sort(constrained,function(a,b)
      local function difficulty(p)
        local direction=p.input.direction or get_cell_dir(p.input.x,p.input.y) or dir_s
        return math.min((direction-dir_e)%16,(dir_e-direction)%16)
      end
      local ad,bd=difficulty(a),difficulty(b);if ad~=bd then return ad>bd end
      local al=math.abs(a.x-a.input.x)+math.abs(a.y-a.input.y);local bl=math.abs(b.x-b.input.x)+math.abs(b.y-b.input.y)
      if al~=bl then return al>bl end;if a.y~=b.y then return a.y<b.y end;return a.x<b.x
    end)
    orders[1]=constrained;orders[2]=near;orders[3]=far
    local reverse={};for i=#ports,1,-1 do reverse[#reverse+1]=ports[i] end;orders[4]=reverse
    local base=generation_work.cached('external-route-base',snapshot,true);local best,best_failures,best_success
    for order_index,order in ipairs(orders) do
      local ran=false
      local result=generation_work.cached('external-order-'..order_index,function()
      ran=true
      if order_index>1 then restore(base) end
      local failures,success=0,{}
      local function connect(port)
        local target=port.input
        if route_bfs(port.x,port.y,target.x,target.y,'external '..port.name,1,get_cell_dir(target.x,target.y) or target.direction or dir_s,false,get_cell_dir(port.x,port.y) or port.direction or dir_e) then
          success[port]=true
          local source_owner,target_owner=key(port.x,port.y),key(target.x,target.y)
          for k,owners in pairs(endpoint_reservations) do
            if owners[source_owner] or owners[target_owner] then
              local updated={};for owner,value in pairs(owners) do if owner~=source_owner and owner~=target_owner then updated[owner]=value end end
              endpoint_reservations[k]=updated
            end
          end
          return true
        end
      end
      local route_state=base
      local direct_connect=connect
      connect=function(port)
        local result=generation_work.cached('external-port',function()
          restore(route_state)
          local ok=direct_connect(port)
          return {snapshot=snapshot(),ok=ok,logs=generation_work.copy(_diag_trial_logs)}
        end,true)
        route_state=result.snapshot;_diag_trial_logs=generation_work.copy(result.logs)
        if result.ok then success[port]=true end
        generation_work.section_boundary()
        return result.ok
      end
      for _,port in ipairs(order) do connect(port) end
      for pass=1,2 do
        local progress=false
        for _,port in ipairs(order) do if not success[port] and connect(port) then progress=true end end
        if not progress then break end
      end
      restore(route_state)
      local indices={}
      for i,port in ipairs(ports) do if success[port] then indices[i]=true else failures=failures+1 end end
      return {snapshot=(not best_failures or failures<best_failures) and route_state or nil,
        failures=failures,success=indices,logs=generation_work.copy(_diag_trial_logs)}
      end,true)
      _diag_trial_logs=generation_work.copy(result.logs)
      if result.failures==0 then
        if not ran then restore(result.snapshot) end
        best=nil;best_failures=0;best_success=result.success;break
      end
      if not best_failures or result.failures<best_failures then
        best=result.snapshot;best_failures=result.failures;best_success=result.success
      end
      generation_work.section_boundary()
    end
    if best then restore(best) end
    for port_index,port in ipairs(ports) do if best_success[port_index] then
      local block=blocks_meta[port.block]
      if block then for _,inlet in ipairs(port.inlets or {{x=port.x,y=port.y,ingredient=port.name,direction=dir_e}}) do block.external_inputs[#block.external_inputs+1]=inlet end end
    else _diag_log('[BFH-external] FAIL '..port.name) end end
    return en,best_failures
  end

  if settings.link_mode~="independent" then
    routing_producers=false
    local failures,connections=0,0
    local tasks={}
    local items={}; for item in pairs(consumers_for) do items[#items+1]=item end; table.sort(items)
    for _,item in ipairs(items) do
      local prods=producers_for[item]
      local groups={}
      for _,p in ipairs(prods) do
        if p.product_out then
          local rate=0
          for _,v in ipairs((p.recipe_node or {}).products or {}) do if v.name==item then rate=rate+get_flow_per_sec(v,p.recipe_node) end end
          -- Rounding machine counts adds potential capacity, not supplied flow.
          -- Inputs still follow the recipe's planned rates. Allocating the
          -- rounded maximum here would spend output without its ingredients.
          groups[#groups+1]={producer=p,cons={},load=0,cells={},paths={},capacity=math.min(rate,belt_throughput(settings.belt_out or belt_in))}
        end
      end
      local consumers={};for _,c in ipairs(consumers_for[item]) do consumers[#consumers+1]=c end
      local bound_item=false
      for _,g in ipairs(groups) do if g.producer.product_out.flow_edge or g.producer.product_out.graph_terminal then bound_item=true end end
      local function intended(g,c)
        local p=g.producer.product_out
        if p.flow_edge then return p.flow_edge==c.input.flow_edge end
        if p.graph_terminal then return c.block.is_external_output and c.block.export.export_slot==p.terminal_slot end
        return not c.input.flow_edge
      end
      table.sort(consumers,function(a,b)
        if a.need_ips~=b.need_ips then return a.need_ips>b.need_ips end
        if a.input.y~=b.input.y then return a.input.y>b.input.y end
        return a.input.x<b.input.x
      end)
        local function add_part(g,c,amount)
          for _,part in ipairs(g.cons) do
            if part.original==c then part.need_ips=part.need_ips+amount;g.load=g.load+amount;return end
          end
          g.cons[#g.cons+1]={block=c.block,input=c.input,need_ips=amount,original=c}
          g.load=g.load+amount
        end
        for _,c in ipairs(consumers) do
          local remaining=math.max(c.need_ips,1e-6)
          local best,score
          for _,g in ipairs(groups) do
            if intended(g,c) and (g.producer._owner or g.producer)~=c.block and g.capacity-g.load>=remaining-1e-8 then
              local src=resources.port(g.producer,item)
              local value=math.abs(src.x-c.input.x)+math.abs(src.y-c.input.y)+g.load/math.max(g.capacity,1e-9)
              if not score or value<score then best,score=g,value end
            end
          end
          if best then add_part(best,c,remaining);remaining=0 end
          while remaining>1e-8 do
            local available=0;best=nil
            for _,g in ipairs(groups) do
              if intended(g,c) and (g.producer._owner or g.producer)~=c.block and g.capacity-g.load>available+1e-8 then best=g;available=g.capacity-g.load end
            end
            if not best then break end
            local amount=math.min(remaining,available);add_part(best,c,amount);remaining=remaining-amount
          end
          if remaining>1e-8 then
            best,score=nil,nil
            for _,g in ipairs(groups) do
              if intended(g,c) and (g.producer._owner or g.producer)~=c.block then
                local value=g.load/math.max(g.capacity,1e-9)
                if not score or value<score then best,score=g,value end
              end
            end
            if best then add_part(best,c,remaining) else failures=failures+1 end
          end
        end
      if #groups>1 and #consumers>1 and not bound_item then
        local matrix,costs,index={},{},{};for i,c in ipairs(consumers) do index[c]=i end
        for i,g in ipairs(groups) do matrix[i]={};costs[i]={};local p=resources.port(g.producer,item)
          for j,c in ipairs(consumers) do
            matrix[i][j]=0;local distance=math.abs(p.x-c.input.x)+math.abs(p.y-c.input.y)
            if g.producer.routing_cluster and g.producer.routing_cluster==c.block.routing_cluster then distance=math.max(0,distance-8) end
            costs[i][j]=(g.producer._owner or g.producer)==c.block and 1e9 or distance
          end
          for _,part in ipairs(g.cons) do matrix[i][index[part.original]]=part.need_ips end
        end
        local locked={}
        for i,g in ipairs(groups) do local part=#g.cons==1 and g.cons[1]
          if part and math.abs(part.need_ips-g.capacity)<1e-8 and math.abs(part.need_ips-part.original.need_ips)<1e-8 then locked[i]=true end
        end
        -- A complete producer/consumer match needs one direct line. Distance
        -- exchanges must not tear it into several fractional branch feeds.
        matrix=local_allocation.optimize(matrix,costs,locked)
        for i,g in ipairs(groups) do g.cons={};g.load=0;for j,c in ipairs(consumers) do if matrix[i][j]>1e-8 then add_part(g,c,matrix[i][j]) end end end
      end
      -- Connect outlets confined between neighbouring groups before open edge
      -- outlets consume their only escape corridor.
      local function clearance(g)
        local p=resources.port(g.producer,item);local v=endpoint_vectors[p.direction or get_cell_dir(p.x,p.y) or dir_s]
        for step=1,16 do local owner=block_cells[key(p.x+v[1]*step,p.y+v[2]*step)]
          if owner and owner~=g.producer.route_owner then return step end
        end
        return 17
      end
      for index,g in ipairs(groups) do g.escape_clearance=clearance(g);g.source_order=index end
      table.sort(groups,function(a,b)if a.escape_clearance~=b.escape_clearance then return a.escape_clearance<b.escape_clearance end;return a.source_order<b.source_order end)
      tasks[#tasks+1]={item=item,groups=groups,receiver_paths={},receiver_supplies={}}
    end
    for _,task in ipairs(tasks) do
      task.clearance=17;task.fanout=0;for _,g in ipairs(task.groups) do task.clearance=math.min(task.clearance,g.escape_clearance or 17);task.fanout=task.fanout+#g.cons end
    end
    table.sort(tasks,function(a,b)if a.clearance~=b.clearance then return a.clearance<b.clearance end;if a.fanout~=b.fanout then return a.fanout>b.fanout end;return a.item<b.item end)
    -- A completed routing phase is immutable. Only the current phase is
    -- replayed after a suspended search; earlier phases retain their geometry,
    -- flow allocations and shared metadata in one serializable graph.
    local function capture_phase()
      return {bundle=routing_bundle,blocks=blocks_meta,tasks=tasks,en=en,
        occupied=occupied,cell_dir=cell_dir,cell_kind=cell_kind,ug_names=ug_names,guards=endpoint_reservations,
        connections=connections,failures=failures,logs=_diag_trial_logs,surface=surface_indices()}
    end
    local function install_phase(state,immutable_entities)
      routing_bundle=state.bundle;blocks_meta=state.blocks;tasks=state.tasks;en=state.en
      list=routing_bundle.entities;settings=routing_bundle.settings
      occupied=state.occupied;cell_dir=state.cell_dir;cell_kind=state.cell_kind;ug_names=state.ug_names or {};endpoint_reservations=state.guards
      connections=state.connections;failures=state.failures;_diag_trial_logs=state.logs
      rebuild_surface_lookup(state.surface,immutable_entities)
    end
    local function consumer_ready(g,c,paths,phase)
      local receiver=c.original or c
      local producer_version=g.connections or 0;local receiver_version=#(paths[receiver] or {})
      local unchanged=c.failed_producer_version==producer_version and c.failed_receiver_version==receiver_version
        and (not route_deep_search or c.failed_deep_search)
      local local_link=g.producer.routing_cluster and g.producer.routing_cluster==c.block.routing_cluster
      local early_export=c.block.is_external_output and g.producer.product_out.graph_terminal and g.escape_clearance<=2
      local eligible=not c.connected and not unchanged and ((c.block.is_external_output and (phase>=5 or (early_export and phase==1)))
        or (not c.block.is_external_output and ((local_link and phase<=2) or (not local_link and phase>=3 and phase<=4))))
      return eligible,receiver,producer_version,receiver_version
    end
    local phase_state=routing_bundle and capture_phase()
    local phase_order=settings.layout_search=='thorough' and {1,2,3,4,5,6} or {1,3,5,2,4,6}
    for _,phase in ipairs(phase_order) do
     route_deep_search=settings.layout_search=='thorough' or phase%2==0
     local function run_phase()
      local task_state=phase_state
     for task_index=1,#tasks do
      local function run_task()
       local probe_task=routing_bundle and task_state.tasks[task_index] or tasks[task_index]
       local needed=false
       for _,g in ipairs(probe_task.groups) do
        for _,c in ipairs(g.cons) do if consumer_ready(g,c,probe_task.receiver_paths,phase) then needed=true;break end end
        if needed then break end
       end
       -- Reuse an immutable snapshot when this material has no work in this phase.
       if not needed then return routing_bundle and task_state or nil end
       if routing_bundle then
        local borrowed={}
        for i,entity in ipairs(task_state.bundle.entities) do borrowed[i]=entity end
        -- Surface indices are immutable; lookup edits use a separate overlay.
        borrowed[#borrowed+1]=task_state.surface
        install_phase(generation_work.fork('task-working',task_state,borrowed),task_state.bundle.entities)
       end
      local task=tasks[task_index]
      local item,groups,receiver_paths,receiver_supplies=task.item,task.groups,task.receiver_paths,task.receiver_supplies
      for _,g in ipairs(groups) do
        local src=resources.port(g.producer,item)
        -- Grow the shared network locally before extending it to distant consumers.
        table.sort(g.cons,function(a,b)
          local ac=(g.producer.routing_cluster and g.producer.routing_cluster==a.block.routing_cluster) and 1 or 0
          local bc=(g.producer.routing_cluster and g.producer.routing_cluster==b.block.routing_cluster) and 1 or 0
          if ac~=bc then return ac>bc end
          local da=math.abs(src.x-a.input.x)+math.abs(src.y-a.input.y)
          local db=math.abs(src.x-b.input.x)+math.abs(src.y-b.input.y)
          if da~=db then return da<db end
          if a.input.y~=b.input.y then return a.input.y<b.input.y end
          return a.input.x<b.input.x
        end)
        local function remember(plan)
          for _,cell in ipairs(plan or {}) do
            g.cells[key(cell.x,cell.y)]=cell
          end
        end
        for _,c in ipairs(g.cons) do
         local eligible,receiver,producer_version,receiver_version=consumer_ready(g,c,receiver_paths,phase)
         if eligible then
          local ci=(g.connections or 0)+1
          local attempts=0
          local function attempt()
            attempts=attempts+1
            if settings.layout_search~='thorough' and attempts>(route_deep_search and 8 or 1) then return false end
            return generation_work.route_attempt()
          end
          route_source_owner=g.producer.route_owner;route_target_owner=receiver.block.route_owner
          route_source_port_key=key(src.x,src.y);route_target_port_key=key(receiver.input.x,receiver.input.y)
          route_is_export=not not c.block.is_external_output
          local function usable(x,y)
            local k=key(x,y);local owner=block_cells[k]
            for reservation in pairs(endpoint_reservations[k] or no_reservations) do
              if reservation~=route_source_port_key and reservation~=route_target_port_key then return false end
            end
            if owner and (machine_cells[k] or (owner~=route_source_owner and owner~=route_target_owner)) then return false end
            local cluster=cluster_cells[k]
            return not cluster or cluster==owner_clusters[route_source_owner] or cluster==owner_clusters[route_target_owner]
          end
          local prior=receiver_paths[receiver]
          local preserve_merges=not prior and c.need_ips+1e-8<(receiver.need_ips or 0)
          local original_input=c.input
          local targets=generation_work.cached('route-targets',function()
          local targets={}
          if prior then
            local vectors=endpoint_vectors
            for pi=#prior,1,-1 do
              local cell=prior[pi]
              local x,y=cell.x,cell.y;local d=get_cell_dir(x,y);local v=vectors[d]
              local next_cell=v and {x=x+v[1],y=y+v[2]}
              if v and get_cell_kind(x,y)=="belt"
                  and (get_cell_kind(x-v[1],y-v[2])=="belt" or get_cell_kind(x-v[1],y-v[2])=="ug_out" or get_cell_kind(x-v[1],y-v[2])=="splitter") and get_cell_dir(x-v[1],y-v[2])==d
                  and next_cell.x==x+v[1] and next_cell.y==y+v[2]
                  and (get_cell_kind(next_cell.x,next_cell.y)=="belt" or ((get_cell_kind(next_cell.x,next_cell.y)=="ug_in" or get_cell_kind(next_cell.x,next_cell.y)=="splitter") and get_cell_dir(next_cell.x,next_cell.y)==d)) then
                for sign=1,-1,-2 do
                  local sx,sy=sign*v[2],-sign*v[1]
                  local xx,yy=x+sx,y+sy
                  -- Both outputs may feed the two inputs of the SAME existing
                  -- splitter. Its inputs already share one material network.
                  local next_owner=splitter_owner[key(x+v[1],y+v[2])]
                  local paired=next_owner and next_owner==splitter_owner[key(xx+v[1],yy+v[2])]
                    and get_cell_kind(x+v[1],y+v[2])=='splitter' and get_cell_kind(xx+v[1],yy+v[2])=='splitter'
                    and get_cell_dir(xx+v[1],yy+v[2])==d
                  if usable(x,y) and usable(xx,yy) and usable(xx-v[1],yy-v[2]) and get_occ(xx,yy)==nil and get_occ(xx-v[1],yy-v[2])==nil and (get_occ(xx+v[1],yy+v[2])==nil or paired) then
                    targets[#targets+1]={input={x=xx-v[1],y=yy-v[2]},merge={x=x,y=y,xx=xx,yy=yy},dir=d}
                  end
                end
              end
            end
          else targets[1]={input={x=c.input.x,y=c.input.y,direction=c.input.direction}} end
          return targets
          end,true)
          local connected,successful_plan,successful_prefix=false,nil,nil
          for _,destination in ipairs(targets) do
            if not attempt() then break end
            local m=destination.merge
            local before_destination=m and trial_snapshot(m.x,m.y,m.xx,m.yy)
            if destination.merge then
              local m=destination.merge;local x,y=m.x,m.y;local d=destination.dir
              remove_surface_belt(x,y)
              en=add_entity_cell(list,en,splitter,math.min(x,m.xx),math.min(y,m.yy),d%8==0 and 2 or 1,d%8==0 and 1 or 2,d,nil,0,0)
              list[#list].input_priority=flow_priorities.merge(receiver_supplies[receiver],c.need_ips,g.load,d,m.xx-x,m.yy-y)
              mark_belt(m.xx,m.yy,"merge",d,"splitter");mark_belt(x,y,"merge",d,"splitter")
            end
            c.input=destination.input
            local final_dir=destination.dir or get_cell_dir(c.input.x,c.input.y) or c.input.direction or dir_s
          if ci==1 then
            if route_bfs(src.x,src.y,c.input.x,c.input.y,item,ci,final_dir,false,
                get_cell_dir(src.x,src.y) or src.direction or dir_s,nil,preserve_merges) then
              connected=true;successful_plan=last_plan;remember(last_plan)

            end
          else
            local taps=generation_work.cached('route-taps',function()
            local taps={}
            for _,cell in pairs(g.cells) do
              local d=get_cell_dir(cell.x,cell.y)
              local vectors=endpoint_vectors
              local v=vectors[d];local sx,sy=v and -v[2],v and v[1]
              for sign=1,-1,-2 do
              local sx,sy=sign*(sx or 0),sign*(sy or 0)
              if v and usable(cell.x,cell.y) and usable(cell.x+sx,cell.y+sy) and usable(cell.x+sx+v[1],cell.y+sy+v[2]) and get_cell_kind(cell.x,cell.y)=="belt"
                  and get_occ(cell.x+sx,cell.y+sy)==nil and get_occ(cell.x+sx+v[1],cell.y+sy+v[2])==nil
                  and g.cells[key(cell.x+v[1],cell.y+v[2])]
                  and (get_cell_kind(cell.x-v[1],cell.y-v[2])=="belt" or get_cell_kind(cell.x-v[1],cell.y-v[2])=="ug_out" or get_cell_kind(cell.x-v[1],cell.y-v[2])=="splitter") and get_cell_dir(cell.x-v[1],cell.y-v[2])==d then
                taps[#taps+1]={x=cell.x,y=cell.y,dir=d,v=v,sx=sx,sy=sy}
              end
              end
            end
            table.sort(taps,function(a,b)
              local da=math.abs(a.x-c.input.x)+math.abs(a.y-c.input.y)
              local db=math.abs(b.x-c.input.x)+math.abs(b.y-c.input.y)
              if da~=db then return da<db end
              if a.y~=b.y then return a.y<b.y end
              return a.x<b.x
            end)
            return taps
            end,true)
            for _,tap in ipairs(taps) do
              if not attempt() then break end
              local x,y=tap.x,tap.y
              local saved=trial_snapshot(x,y,x+tap.sx,y+tap.sy)
              remove_surface_belt(x,y)
              local d,v,sx,sy=tap.dir,tap.v,tap.sx,tap.sy
              en=add_entity_cell(list,en,splitter,math.min(x,x+sx),math.min(y,y+sy),d%8==0 and 2 or 1,d%8==0 and 1 or 2,d,nil,0,0)
              local downstream,prefix={},nil
              for _,path in ipairs(g.paths) do
                for pi,cell in ipairs(path.cells) do if cell.x==x and cell.y==y then
                  downstream[#downstream+1]=path
                  if not prefix then prefix={};for j=1,pi do prefix[#prefix+1]=path.cells[j] end end
                  break
                end end
              end
              if c.block.is_external_output then list[#list].output_priority=flow_priorities.half(d,sx,sy,false)
              else list[#list].output_priority=flow_priorities.merge(downstream,c.need_ips,receiver.need_ips or c.need_ips,d,sx,sy) end
              mark_belt(x+sx,y+sy,"branch",d,"splitter")
              mark_belt(x,y,"route",d,"splitter")
              if route_bfs(x+sx+v[1],y+sy+v[2],c.input.x,c.input.y,item,ci,final_dir,false,d,nil,preserve_merges) then
                connected=true;successful_plan=last_plan;successful_prefix=prefix;remember(last_plan);break
              end
              restore_trial(saved)
            end
          end
            c.input=original_input
            if connected then
              if not prior then
                local cells={};for _,cell in ipairs(successful_plan or {}) do cells[#cells+1]=cell end
                receiver_paths[receiver]=cells
              else
                local seen={};for _,cell in ipairs(prior) do seen[key(cell.x,cell.y)]=true end
                for _,cell in ipairs(successful_plan or {}) do local k=key(cell.x,cell.y)
                  if not seen[k] then prior[#prior+1]=cell;seen[k]=true end
                end
              end
              break
            end
            restore_trial(before_destination)
          end
          if not connected then c.failed_producer_version=producer_version;c.failed_receiver_version=receiver_version;c.failed_deep_search=route_deep_search end
          if connected then
            connections=connections+1;g.connections=ci;c.connected=true
            if ci==1 and src.buffered_distribution then
              local tiles=0
              for i=2,#(successful_plan or {}) do local a,b=successful_plan[i-1],successful_plan[i]
                tiles=tiles+math.abs(a.x-b.x)+math.abs(a.y-b.y)
              end
              local prefix_tiles=0
              for i=1,#(successful_plan or {})-1 do local a,b=successful_plan[i],successful_plan[i+1]
                if a.kind=='belt' and b.kind=='belt' and math.abs(a.x-b.x)+math.abs(a.y-b.y)==1 then
                  src.flow_buffer={gate={x=a.x,y=a.y},reader={x=b.x,y=b.y},tiles=tiles,prefix_tiles=prefix_tiles,rate=c.need_ips,item=item}
                  break
                end
                prefix_tiles=prefix_tiles+math.abs(a.x-b.x)+math.abs(a.y-b.y)
              end
            end
            -- Once an outlet has a physical path, later branches use that
            -- path. Its unused turning apron must not remain an invisible wall.
            if ci==1 then release_owner(route_source_port_key) end
            local path={};for _,cell in ipairs(successful_prefix or {}) do path[#path+1]=cell end
            for _,cell in ipairs(successful_plan or {}) do path[#path+1]=cell end
            g.paths[#g.paths+1]={cells=path,rate=c.need_ips,load=receiver.need_ips or c.need_ips}
            c.input.connected_rate=(c.input.connected_rate or 0)+c.need_ips
            if c.input.connected_rate+1e-8>=(receiver.need_ips or c.need_ips) then
              release_owner(route_target_port_key)
            end
            receiver_supplies[receiver]=receiver_supplies[receiver] or {}
            receiver_supplies[receiver][#receiver_supplies[receiver]+1]={rate=c.need_ips,load=g.load}
            if c.block.export then
              local target=c.block.export
              if target.flow then target.flow.allocated=target.flow.allocated+c.need_ips end
              target.sources[#target.sources+1]={x=src.x,y=src.y,direction=src.direction,rate=c.need_ips}

            end
          end
         end
        end
      end
            if routing_bundle then return capture_phase() end
      end
      if routing_bundle then
       task_state=generation_work.cached('solid-task-'..task_index,run_task,true)
       generation_work.section_boundary()
      else run_task() end
     end
      if routing_bundle then return task_state end
     end
     if routing_bundle then
       phase_state=generation_work.cached('solid-phase-'..phase,run_phase,true)
       generation_work.section_boundary()
     else run_phase() end
    end
    if routing_bundle then
      install_phase(phase_state,phase_state.bundle.entities)
      -- Final diagnostics and the caller may edit the outer bundle and logs;
      -- the completed phase snapshot itself remains immutable.
      local outer={};for k,v in pairs(routing_bundle) do outer[k]=v end;routing_bundle=outer
      _diag_trial_logs=generation_work.copy(_diag_trial_logs)
    end
    for _,task in ipairs(tasks) do for _,g in ipairs(task.groups) do for _,c in ipairs(g.cons) do if not c.connected then
      failures=failures+1
      _diag_log(string.format("[BFH-direct] FAIL %s -> (%d,%d)",task.item,c.input.x,c.input.y))
    end end end end
    _diag_log(string.format("[BFH-direct] Connections: %d OK, %d FAIL",connections,failures))
    if _diag_player and failures>0 then _diag_player.print({"bfh.routing-incomplete",failures}) end
    return en,failures,routing_bundle
  end

  -- ── Главный цикл соединений ──
  -- Сортируем продукты — сначала простые (1 потребитель)
  local sorted_ings = {}
  for ing, _ in pairs(consumers_for) do
    sorted_ings[#sorted_ings + 1] = ing
  end
  table.sort(sorted_ings, function(a, b)
    return #consumers_for[a] < #consumers_for[b]
  end)

  -- Ранняя диагностика
  if _diag_log_buffer or _diag_player then
    local prod_count = 0
    for _, _ in pairs(producer_for) do prod_count = prod_count + 1 end
    local cons_count = 0
    for _, _ in pairs(consumers_for) do cons_count = cons_count + 1 end
    _diag_log(string.format(
      "[BFH] Блоков: %d, продуктов: %d, продуктов с потребителями: %d",
      #blocks_meta, prod_count, cons_count))
    for i, b in ipairs(blocks_meta) do
      local inputs_str = ""
      if b.inputs then
        for _, inp in ipairs(b.inputs) do
          inputs_str = inputs_str .. string.format(" '%s'(%d,%d)", inp.ingredient or "?", inp.x, inp.y)
        end
      end
      _diag_log(string.format(
        "[BFH] блок%d: x=%d..%d y=%d..%d product_out=(%d,%d) inputs:%s",
        i, b.offset_x, b.offset_x + b.width - 1,
        b.offset_y, b.offset_y + b.height - 1,
        b.product_out and b.product_out.x or -999,
        b.product_out and b.product_out.y or -999,
        inputs_str))
    end
    for ing, consumers in pairs(consumers_for) do
      _diag_log(string.format("[BFH]   '%s' → %d потребителей", ing, #consumers))
    end
  end

  -- ── ШАГ 1: Прокладка магистралей ──
  -- Для каждого продукта с потребителями: определить N=количество производителей,
  -- выбрать X-положение магистрали справа от всех блоков, проложить N параллельных
  -- вертикальных лент от верхнего producer'а до нижнего consumer'а.
  -- Промежутки магистралей разделяем зазором по X.

  -- Сначала найдём max X всех блоков (правее этой границы — место для магистралей)
  -- Four empty columns after the actual rotated entity footprint.
  local trunk_x_start = max_block_x + 5

  -- Информация о магистралях: trunks[item] = { x_start, lane_count, y_top, y_bot, lanes = { x1, x2, ... } }
  local trunks = {}

  -- Сортируем продукты по числу потребителей убыванием, чтобы более востребованные
  -- магистрали шли ближе к блокам.
  local trunk_order = {}
  for ing, _ in pairs(consumers_for) do
    trunk_order[#trunk_order + 1] = ing
  end
  table.sort(trunk_order, function(a, b)
    if #consumers_for[a] == #consumers_for[b] then return a < b end
    return #consumers_for[a] > #consumers_for[b]
  end)

  -- ОТЛАДКА: единый лимит на число продуктов, для которых строится магистраль И
  -- подключения. _STEP_LIMIT=1 → 1 магистраль + её подключения; 2 → две; и т.д.
  -- math.huge — обрабатывать все продукты.
  local _STEP_LIMIT = math.huge
  do
    local limited = {}
    for i = 1, math.min(_STEP_LIMIT, #trunk_order) do
      limited[i] = trunk_order[i]
    end
    trunk_order = limited
  end

  local trunks = {}
  local _conn_ok, _conn_fail = 0, 0

  -- ── ШАГИ 1+2 ОБЪЕДИНЕНЫ ──
  -- Магистраль НЕ строится заранее. Для каждого продукта:
  --  1. producer'ы сортируются по близости к зоне магистрали;
  --  2. дальняя лента магистрали (макс X) обслуживается producer'ом на ВЕРХНЕЙ строке,
  --     каждый следующий (ближе) — на строку ниже;
  --  3. producer прокладывается route_bfs до точки НАД своей колонкой (заход ↓);
  --  4. от точки захода вниз тянется ЛЕНТА МАГИСТРАЛИ до нижнего потребителя.
  -- Так магистраль "вырастает" из поворотов producer'ов — без влива сбоку.
  local reserved_x=trunk_x_start
  local bus_bottom=-math.huge
  for _,cons in pairs(consumers_for) do
    for _,c in ipairs(cons) do bus_bottom=math.max(bus_bottom,c.input.y) end
  end
  for _,item in ipairs(trunk_order) do
    local prods=producers_for[item] or {}
    local cons=consumers_for[item] or {}
    if #prods>0 and #cons>0 then
      local first_y=math.huge
      for _,p in ipairs(prods) do
        if p.product_out then first_y=math.min(first_y,p.product_out.y-2) end
      end
      for _,c in ipairs(cons) do first_y=math.min(first_y,c.input.y-6-#prods) end
      for li=0,#prods-1 do
        local x=reserved_x+li*LANE_SPACING
        for y=first_y,bus_bottom do
          if get_occ(x,y)==nil then mark(x,y,"reserved") end
          reserved_taps[key(x-1,y)]=true
        end
      end
      reserved_x=reserved_x+#prods*LANE_SPACING+2
    end
  end
  local cur_x = trunk_x_start
  for _, item in ipairs(trunk_order) do
    local prods = producers_for[item] or {}
    local cons = consumers_for[item] or {}
    if #prods >= 1 and #cons >= 1 then
      local lane_count = #prods

      -- Нижняя граница магистрали — самый нижний потребитель
      local y_bot = -math.huge
      for _, c in ipairs(cons) do
        if c.input.y > y_bot then y_bot = c.input.y end
      end
      if y_bot == -math.huge then goto skip_trunk end

      -- producer'ы по близости к зоне магистрали (ближний — первым)
      local prod_order = {}
      for idx, p in ipairs(prods) do
        if p.product_out then prod_order[#prod_order + 1] = p end
      end
      table.sort(prod_order, function(a, b)
        return math.abs(a.product_out.x - cur_x) < math.abs(b.product_out.x - cur_x)
      end)

      -- Базовая строка влива = НИЖЕ самого нижнего product_out на 2 клетки,
      -- чтобы любой producer достигал её только спуском (no_up запрещает подъём).
      local base_y = -math.huge
      for _, p in ipairs(prod_order) do
        if p.product_out.y > base_y then base_y = p.product_out.y end
      end
      base_y = base_y + 2
      for _,c in ipairs(cons) do base_y=math.min(base_y,c.input.y-6-#prod_order) end

      -- Колонки магистрали: cur_x .. cur_x+lane_count-1.
      -- Ближний к шине producer (order 1) → ДАЛЬНЯЯ колонка магистрали + ВЕРХНЯЯ строка:
      -- его горизонталь идёт выше всех и заходит в дальнюю ленту, проходя над ближними.
      -- Чем дальше producer от шины — тем ближе его колонка и тем НИЖЕ строка влива.
      local lanes = {}
      local lane_tops = {}  -- y, с которого начинается лента магистрали в колонке
      local np = #prod_order
      for order_i, p in ipairs(prod_order) do
        -- order 1 → дальняя колонка (cur_x + np - 1); order np → ближняя (cur_x)
        local lane_x = cur_x + (np - order_i)*LANE_SPACING
        lanes[order_i] = lane_x
        -- order 1 → верхняя строка (base_y); каждый следующий — на клетку ниже
        local merge_y = base_y + (order_i - 1)
        if merge_y > y_bot then merge_y = y_bot end
        lane_tops[order_i] = merge_y

        local from_x = p.product_out.x
        local from_y = p.product_out.y
        _diag_log(string.format(
          "[BFH-conn] try '%s' #%d: producer(%d,%d) → колонка x=%d, влив сбоку в (%d,%d)",
          item, order_i, from_x, from_y, lane_x, lane_x, merge_y))

        -- Магистраль колонки идёт ↓ от merge_y вниз. Producer приходит горизонтально
        -- и упирается в верхнюю клетку магистрали (T-junction sideload):
        -- цель маршрута — клетка (lane_x-1, merge_y), заход с направлением → (dir_e),
        -- последняя лента → вливается в магистраль ↓ сбоку.
        local route_to_x = lane_x
        if route_bfs(from_x, from_y, route_to_x, merge_y, item, order_i, dir_s, false) then
          _conn_ok = _conn_ok + 1
          _diag_log("[BFH-conn]   OK")
          mark_belt(lane_x,merge_y,"trunk",dir_s,get_cell_kind(lane_x,merge_y))
          -- Лента магистрали: от merge_y вниз до y_bot в колонке lane_x
          for y = merge_y+1, y_bot do
            local occ = get_occ(lane_x, y)
            if occ == nil or occ == "reserved" then
              en = add_entity_cell(list, en, belt_in, lane_x, y, 1, 1, dir_s, nil, 0, 0)
              mark_belt(lane_x, y, "trunk", dir_s, "belt")
            end
          end
        else
          lane_tops[order_i] = math.huge
          _conn_fail = _conn_fail + 1
          _diag_log("[BFH-conn]   FAIL")
        end
      end

      local y_top_trunk = math.huge
      for _, ly in ipairs(lane_tops) do
        if ly < y_top_trunk then y_top_trunk = ly end
      end
      trunks[item] = {
        x_start = cur_x, lane_count = lane_count,
        y_top = y_top_trunk, y_bot = y_bot,
        lanes = lanes, lane_tops = lane_tops,
      }
      cur_x = cur_x + lane_count*LANE_SPACING + 2
      ::skip_trunk::
    end
  end

  local _routes_attempted = 0
  local _routes_success = 0
  local _failed_routes = {}

  local incoming_count = {}
  local outgoing_count = {}
  local approach_in = {}

  _diag_log(string.format("[BFH] Подключение producer→магистраль: %d OK, %d FAIL",
    _conn_ok, _conn_fail))

  -- Every consumer gets an independently planned splitter branch.
  -- Snapshot the whole routing transaction, including replaced trunk belts.
  local _br_ok,_br_fail=0,0
  routing_producers=false
  for _,item in ipairs(trunk_order) do
    local trunk=trunks[item]
    if trunk then
      local cons=consumers_for[item] or {}
      table.sort(cons,function(a,b)
        if a.input.y~=b.input.y then return a.input.y<b.input.y end
        return a.input.x>b.input.x
      end)
      local lane_uses,lane_pending={},{}
      for li=1,#trunk.lanes do lane_uses[li]=0;lane_pending[li]=0 end
      for _,c in ipairs(cons) do
        local selected=1
        for li=2,#trunk.lanes do
          if lane_uses[li]<lane_uses[selected] then selected=li end
        end
        c.lane=selected
        lane_uses[selected]=lane_uses[selected]+math.max(c.need_ips or 0,1)
        lane_pending[selected]=lane_pending[selected]+1
      end
      for li=1,#trunk.lanes do lane_uses[li]=0 end
      for _,c in ipairs(cons) do
        local connected=false
        -- Spread split consumers across producer lanes before trying alternatives.
        local lane_order={c.lane}
        for _,li in ipairs(lane_order) do
          if connected then break end
          local lx=trunk.lanes[li]
          for shift=0,30 do
            local y=c.input.y-2-shift
            if y>=(trunk.lane_tops[li] or trunk.y_top) and y+1<=trunk.y_bot
                and get_occ(lx-1,y)==nil and get_occ(lx-1,y+1)==nil
                and get_occ(lx,y)=="trunk" and get_cell_kind(lx,y)=="belt"
                and get_cell_kind(lx,y+1)=="belt" then
              local saved=snapshot()
              if lane_pending[li]==1 then
                -- No consumers downstream: terminate the lane directly at this input.
                for cut=y,trunk.y_bot do
                  if get_occ(lx,cut)=="trunk" and get_cell_kind(lx,cut)=="belt" then
                    remove_surface_belt(lx,cut)
                    occupied[key(lx,cut)]=nil;cell_dir[key(lx,cut)]=nil;cell_kind[key(lx,cut)]=nil
                  end
                end
                mark(lx,y,"io")
                local input_dir=get_cell_dir(c.input.x,c.input.y) or c.input.direction or dir_s
                if route_bfs(lx,y,c.input.x,c.input.y,item,1,input_dir,false,dir_s) then
                  connected=true;lane_pending[li]=0;_br_ok=_br_ok+1;break
                end
                restore(saved)
              else
              remove_surface_belt(lx,y)
              en=add_entity_cell(list,en,splitter,lx-1,y,2,1,dir_s,nil,0,0)
              mark_belt(lx-1,y,"branch",dir_s,"splitter")
              mark_belt(lx,y,"trunk",dir_s,"splitter")
              -- The source receives only the intentionally selected splitter output.
              local input_dir=get_cell_dir(c.input.x,c.input.y) or c.input.direction or dir_s
              if route_bfs(lx-1,y+1,c.input.x,c.input.y,item,1,input_dir,false,dir_s) then
                connected=true; lane_uses[li]=lane_uses[li]+1; lane_pending[li]=lane_pending[li]-1; _br_ok=_br_ok+1; break
              end
              restore(saved)
              end
            end
          end
        end
        if not connected then
          _br_fail=_br_fail+1
          _diag_log(string.format("[BFH-branch] FAIL %s -> (%d,%d); retained existing belts",
            item,c.input.x,c.input.y))
        end
      end
    end
  end
  _diag_log(string.format("[BFH] Branches: %d OK, %d FAIL",_br_ok,_br_fail))
  if _diag_player and (_conn_fail+_br_fail)>0 then
    _diag_player.print({"bfh.routing-incomplete",_conn_fail+_br_fail})
  end

  return en
end


generation_work.register('layout-footprint-blocks',function(args,state)
  if not state.blocks then
    state.copy=state.copy or {borrowed=args.entities}
    local done,blocks=generation_work.copy_step(args.blocks,state.copy)
    if not done then return false end
    state.blocks=blocks;state.copy=nil;state.index=1;state.properties={}
  end
  local all=args.entities
    local properties=state.properties
    local function shape(name)
      local p=properties[name]
      if not p then local proto=prototypes.entity[name];p={tile_width=proto.tile_width,tile_height=proto.tile_height,type=proto.type};properties[name]=p end
      return p
    end
  while state.index<=#state.blocks do
    if not generation_work.consume(64) then return false end
    local b=state.blocks[state.index]
      local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
      for i=b.entity_first,b.entity_last do
        local e=all[i];local p=shape(e.name)
        local w,h=p.tile_width,p.tile_height
        if e.direction==4 or e.direction==12 then w,h=h,w end
        left=math.min(left,math.floor(e.position.x-w/2+0.001))
        top=math.min(top,math.floor(e.position.y-h/2+0.001))
        right=math.max(right,math.ceil(e.position.x+w/2-0.001)-1)
        bottom=math.max(bottom,math.ceil(e.position.y+h/2-0.001)-1)
      end
      if b.protected_bounds then
        local p=b.protected_bounds;left=math.min(left,p.left);top=math.min(top,p.top)
        right=math.max(right,p.right-1);bottom=math.max(bottom,p.bottom-1)
      end
      b.layout_left=left;b.layout_top=top
      b.layout_width=right-left+1;b.layout_height=bottom-top+1
      b.layout_belt_guards={}
      for _,p in ipairs(b.junction_guards or {}) do b.layout_belt_guards[#b.layout_belt_guards+1]=generation_work.copy(p) end
      local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
      for i=b.entity_first,b.entity_last do
        local e=all[i];local p=shape(e.name);local dir=e.direction or 0
        if p.type=='transport-belt' or p.type=='splitter' or (p.type=='underground-belt' and e.type=='output') then
          local w,h=p.tile_width,p.tile_height;if dir==4 or dir==12 then w,h=h,w end
          local x,y=math.floor(e.position.x-w/2+.001),math.floor(e.position.y-h/2+.001);local v=vectors[dir]
          for dx=0,w-1 do for dy=0,h-1 do
            local xx,yy=x+dx+v[1],y+dy+v[2]
            if xx<left or xx>right or yy<top or yy>bottom then b.layout_belt_guards[#b.layout_belt_guards+1]={x=xx,y=yy} end
          end end
        end
      end
      b.layout_input_dirs={}
      local function port_direction(port)
        if not port then return 8 end
        for i=b.entity_first,b.entity_last do local e=all[i]
          if math.floor(e.position.x)==port.x and math.floor(e.position.y)==port.y then
            local kind=shape(e.name).type
            if kind=='transport-belt' or kind=='underground-belt' then return e.direction or 0 end
          end
        end
        return 8
      end
      for i,port in ipairs(b.inputs or {}) do b.layout_input_dirs[i]=port_direction(port);port.direction=b.layout_input_dirs[i] end
      b.layout_output_dir=port_direction(b.product_out)
      if b.product_out then b.product_out.direction=b.layout_output_dir end
      if b.output_ports and #(b.recipe_node.products or {})==1 then
        local item=b.recipe_node.products[1];b.layout_output_ports={}
        for _,p in ipairs(b.output_ports) do b.layout_output_ports[#b.layout_output_ports+1]={x=p.x,y=p.y,direction=p.direction or b.layout_output_dir,product=item.name,flow_edge=p.flow_edge,graph_terminal=p.graph_terminal,terminal_slot=p.terminal_slot,rate=get_flow_per_sec(item,b.recipe_node)*(p.share or 1)} end
      end
      local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
      local function guard(p,d,sign)
        if not p then return end;local v=vectors[d or p.direction or 8]
        b.layout_belt_guards[#b.layout_belt_guards+1]={x=p.x+sign*v[1],y=p.y+sign*v[2]}
      end
      guard(b.product_out,b.layout_output_dir,1)
      for _,p in ipairs(b.output_ports or {}) do guard(p,p.direction,1) end
      for _,p in pairs(b.product_outs or {}) do guard(p,p.direction,1) end
      for ii,p in ipairs(b.inputs or {}) do if not p.array_local then guard(p,b.layout_input_dirs[ii],-1) end end
    state.index=state.index+1
    if generation_work.is_active() and state.index<=#state.blocks then return false end
  end
  return true,state.blocks
end)

local function build_blueprint_entities(recipes, settings, fastest_belts)
  local blacklist_error=entity_blacklist.check(settings,recipes)
  if blacklist_error then error(blacklist_error,0) end
  -- Включаем буфер лога — сбрасывается в script-output/bfh-routing.log в конце.
  _diag_log_buffer = {}
  _capacity_warned={}
  _diag_log(string.format("[BFH] === build_blueprint_entities: рецептов=%d ===", #recipes))

  local export_requirements=generation_work.cached('export-requirements',function()return output_flows.balance(quality_flows.encode(recipes))end,true)
  recipes=generation_work.cached('production-reserve',function()return production_reserve.apply(recipes,settings.reserve_percent)end,true)
  recipes=generation_work.cached('quality-flows',function()return quality_flows.encode(recipes)end,true)
  local output_rates={}
  for _,r in ipairs(recipes) do for _,v in ipairs(r.products or {}) do if v.type~='fluid' then output_rates[v.name]=(output_rates[v.name] or 0)+get_flow_per_sec(v,r) end end end
  generation_work.phase('blocks',0.01)
  local transfer_force=(_diag_player and _diag_player.force) or (game and game.forces[settings.force_name or 'player'])
  transport_quality.validate(settings.transport_quality,transfer_force)
  local transfer_catalog=generation_work.cached('transfer-catalog',function()return transfer_planner.catalog(transfer_force,settings.entity_blacklist)end,true)
  local transfer_bonuses=generation_work.cached('transfer-bonuses',function()
    return {inserter_stack_size_bonus=transfer_force and transfer_force.inserter_stack_size_bonus or 0,
      bulk_inserter_capacity_bonus=transfer_force and transfer_force.bulk_inserter_capacity_bonus or 0}
  end,true)
  recipes=generation_work.cached('effective-beacons',function()return helmod_equipment.plan_beacons(recipes,transfer_catalog.items)end,true)
  if settings.link_mode~='independent' then recipes=generation_work.cached('production-groups',function()return production_groups.combine(recipes)end,true) end
  local auto_equipment
  if settings.transfer_mode=='auto_equipment' then
    auto_equipment=generation_work.cached('automatic-equipment',function()
      local unlocked={}
      for _,name in pairs(transfer_catalog.items) do unlocked[name]=true end
      local belts={}
      for _,belt in ipairs(get_belt_items(transfer_force,transfer_catalog.items)) do
        local underground,splitter=to_underground(belt),to_splitter(belt)
        local speed=capacity_planner.belt(belt)
        if unlocked[underground] and unlocked[splitter]
          and capacity_planner.belt(underground)>=speed and capacity_planner.belt(splitter)>=speed then
          belts[#belts+1]=belt
        end
      end
      if #belts==0 then error({'bfh.auto-equipment-no-belts'},0) end
      if fastest_belts then return {input=belts[#belts],output=belts[#belts],fastest=belts[#belts]} end
      local connected=settings.link_mode~='independent'
      return capacity_planner.auto_belts(recipes,belts,connected and output_flows.balance(recipes,true) or {},connected and export_requirements or {})
    end,true)
    settings=generation_work.copy(settings)
    settings.belt_in,settings.belt_out=auto_equipment.input,auto_equipment.output
    settings.transfer_mode='auto';settings.loader_name='auto'
  end
  local fmf_catalog
  if settings.fluid_mode=='fmf' then
    local has_fluid=false
    for _,r in ipairs(recipes) do for _,side in ipairs({'ingredients','products'}) do for _,v in pairs(r[side] or {}) do if v.type=='fluid' then has_fluid=true end end end end
    if has_fluid then
      fmf_catalog=generation_work.cached('fmf-catalog',function()return fmf.catalog(transfer_force,settings.pipe,transfer_catalog.items)end,true)
      if not fmf_catalog.available then error({'bfh.fmf-unavailable'},0) end
    end
  end
  local function production_blocks(allow_parallel,allow_shared_beacons)
  _diag_log_buffer={}
  local all = {}
  local en  = 1
  local oy  = 0
  local cache = {}


  -- Реверс порядка рецептов: в Helmod финал сверху, сырьё снизу.
  -- В чертеже хотим наоборот — сырьё сверху, финал снизу.
  local reversed = {}
  for i = #recipes, 1, -1 do
    reversed[#reversed + 1] = recipes[i]
  end

  -- Зазор между подблоками одного рецепта (по горизонтали) — 1 клетка.
  local SUBBLOCK_GAP_X = 1

  -- Собираем все блоки и их метаданные
  local blocks_meta = {}
  for recipe_index, r in ipairs(reversed) do
    helmod_equipment.validate_recipe(r)
    -- Сколько подблоков для этого рецепта (по пропускной способности лент)?
    local physical_recipe=quality_flows.physical(r)
    local parallel_config=allow_parallel and parallel_solid.plan(physical_recipe,settings,transfer_catalog,transfer_bonuses)
    physical_recipe.parallel_outputs=not not parallel_config
    local split_count,capacities,overloaded = compute_split_count(physical_recipe, settings)
    if overloaded then warn_capacity(r.name,"one machine exceeds selected belt capacity") end
    _diag_log("[BFH-capacity] "..tostring(r.name)..": blocks="..split_count)
    for _,d in ipairs(capacities) do
      _diag_log(string.format("[BFH-capacity] %s %s: %.6g/s; capacity %.6g/s",d.side,d.item,d.flow,d.single_block_capacity or d.capacity))
    end
    local total_count = get_machine_count(r)
    if beacon_planner.has(r) then split_count=total_count end
    if split_count < 1 then split_count = 1 end
    if split_count > total_count then split_count = total_count end

    -- Распределение машин: первые (total mod split) подблоков получают ceil, остальные floor
    local base = math.floor(total_count / split_count)
    local extra = total_count - base * split_count   -- столько подблоков с ceil
    local bank_counts={};for i=1,split_count do bank_counts[i]=base+(i<=extra and 1 or 0) end
    local machine = prototypes.entity[r.factory.name]
    local solid_inputs, fluid_inputs = #get_ingredient_names(physical_recipe), #get_fluid_ingredients(physical_recipe)
    local mixed_beacon_bank = machine.type == 'assembling-machine'
      and machine.tile_width == machine.tile_height and machine.tile_width >= 3
      and solid_inputs >= 3 and solid_inputs <= 4 and fluid_inputs == 1
      and #physical_recipe.products == 1 and physical_recipe.products[1].type ~= 'fluid'
    if allow_shared_beacons and total_count>=2 and not parallel_config
      and beacon_planner.can_share(r) and physical_recipe.quality_outputs==1
      and prototypes.entity[r.factory.name].type=='assembling-machine'
      and (mixed_beacon_bank or (#physical_recipe.ingredients>=1 and #physical_recipe.ingredients<=2))
      and physical_recipe.products[1].type~='fluid' then
      local filled=flow_partition.counts(physical_recipe,total_count,settings,split_count,mixed_beacon_bank)
      if filled and filled[1]>=2 then
        local rows=math.huge
        local machine_height=prototypes.entity[r.factory.name].tile_height
        for _,beacon in ipairs(helmod_equipment.beacons(r)) do
          local prototype=prototypes.entity[beacon.name]
          local radius=prototype.get_supply_area_distance(beacon.quality or 'normal') or 0
          rows=math.min(rows,math.ceil((prototype.tile_height+2*radius)/machine_height)+1)
        end
        local group_size=math.min(filled[1],2*rows)
        bank_counts={}
        for remaining=total_count,1,-group_size do
          bank_counts[#bank_counts+1]=math.min(group_size,remaining)
        end
        split_count=#bank_counts
      end
    end
    if settings.link_mode~='independent' and not beacon_planner.has(r) then local filled=flow_partition.counts(physical_recipe,total_count,settings,split_count);if filled then bank_counts=filled;split_count=#filled end end
    local bank_ratios=flow_partition.ratios(physical_recipe,bank_counts,settings)

    local ox = 0
    local row_max_h = 0
    local function build_bank_once(sub_count,ratio)
      local shared=sub_count>=2 and beacon_planner.has(r)
      -- Создаём копию узла рецепта с урезанным factory.count
      local sub_node = {}
      for k, v in pairs(r) do sub_node[k] = v end
      sub_node.factory = {}
      for k, v in pairs(r.factory or {}) do sub_node.factory[k] = v end
      sub_node.factory.count = sub_count
      local fractional_count=tonumber((r.factory or {}).count) or total_count
      local active_count=fractional_count*ratio
      sub_node.physical_capacity_factor=active_count>0 and sub_count/active_count or 1
      for _,field in ipairs({"ingredients","products"}) do
        sub_node[field]={}
        for _,item in pairs(r[field] or {}) do
          local copy={}; for k,v in pairs(item) do copy[k]=v end
          if type(copy.amount)=="number" then copy.amount=copy.amount*ratio end
          if type(copy.count)=="number" then copy.count=copy.count*ratio end
          sub_node[field][#sub_node[field]+1]=copy
        end
      end

      local physical_node=quality_flows.physical(sub_node)
      local first_entity=#all+1
      local block_h, meta
      local original_en=en
      local shell=generation_work.cached('bank-template',function()
        local first_log=#_diag_log_buffer
        local ok=(function()
      local sub_parallel=parallel_config and parallel_solid.plan(physical_node,settings,transfer_catalog,transfer_bonuses)
      if sub_parallel and sub_count>1 then
        en,block_h,meta=parallel_solid.build(physical_node,settings,sub_parallel,ox,oy,en,all,
          function(n,w,b,x,y,id,es) if n==1 then return build_header_1ing(w,b,x,y,id,es) else return build_header_2ing(w,b,x,y,id,es) end end)
      else
        local function header(n,w,b,x,y,id,es)
          if n==1 then return build_header_1ing(w,b,x,y,id,es) end
          return build_header_2ing(w,b,x,y,id,es)
        end
        local beacon_width
        if shared and sub_count>2 then
          local beacon=helmod_equipment.beacons(r)[1]
          beacon_width=prototypes.entity[beacon.name].tile_width
        end
        en,block_h,meta=direct_solid.build(physical_node,settings,get_machine_name(sub_node,cache),sub_count,ox,oy,en,all,transfer_catalog,transfer_bonuses,header,beacon_width)
      end
      if shared and not en and mixed_beacon_bank then
        local output_rate = get_flow_per_sec(physical_node.products[1], physical_node)
        if output_rate * math.ceil(sub_count / 2) / sub_count <= belt_throughput(settings.belt_out) / 2 then
          local beacon = helmod_equipment.beacons(r)[1]
          local bay = prototypes.entity[beacon.name].tile_width
          en,block_h,meta = build_block(physical_node,ox,oy,settings,original_en,all,cache,bay)
        end
      end
      if shared and not en then en=original_en;return false end
      if not en then en,block_h,meta=many_solid.build(physical_node,settings,get_machine_name(sub_node,cache),sub_count,ox,oy,original_en,all,transfer_catalog,transfer_bonuses,to_underground(settings.belt_in),to_underground(settings.belt_out)) end
      if not en then en,block_h,meta=three_solid.build(physical_node,settings,get_machine_name(sub_node,cache),sub_count,ox,oy,original_en,all,transfer_catalog,transfer_bonuses,
        function(n,w,b,x,y,id,es)return build_header_2ing(w,b,x,y,id,es)end) end
      if not en then en=original_en;en,block_h,meta=build_block(physical_node,ox,oy,settings,en,all,cache) end
      if meta then
        local factory=prototypes.entity[sub_node.factory.name]
        if not beacon_planner.has(sub_node) then
          local solid=true;for _,side in ipairs({'ingredients','products'}) do for _,v in ipairs(sub_node[side] or {}) do if v.type=='fluid' then solid=false end end end
          if solid then meta.production_group=recipe_index;meta.spatial_group=production_groups.spatial_key(sub_node) end
        end
        if split_count>1 and factory.type=='furnace' and factory.tile_width==2 and factory.tile_height==2 and not beacon_planner.has(sub_node) then
          local solid=true;for _,side in ipairs({'ingredients','products'}) do for _,v in ipairs(sub_node[side] or {}) do if v.type=='fluid' then solid=false end end end
          if solid then meta.furnace_array=recipe_index end
        end
        meta.recipe_node = sub_node
        meta.inputs = meta.inputs or {}
        meta.products = meta.products or {}
        meta.ingredients = meta.ingredients or {}
        meta.fluid_inputs = meta.fluid_inputs or {}
        meta.fluid_outputs = meta.fluid_outputs or {}
      end
      for j=first_entity,#all do
        local e=all[j];local kind=prototypes.entity[e.name].type
        if e.name==sub_node.factory.name then
          helmod_equipment.apply(e,sub_node.factory,sub_node.name)
          if sub_node.quality and sub_node.quality~='normal' and e.recipe and kind~='furnace' then e.recipe_quality=sub_node.quality end
        end
      end
      -- Для обычных блоков добавляем ленту `v` на 1 клетку выше входа (чтобы подводящая
      -- лента зашла выше сборщика). Для single-блока входы уже полностью построены
      -- (Т-стыки/ленты) — расширение НЕ нужно, оно сломало бы схему.
      if meta and meta.inputs and not meta.is_single_assembler_block then
        for _, inp in ipairs(meta.inputs) do
          if inp.x and inp.y then
            local new_y = inp.y - 1
            en = add_entity_cell(all, en, settings.belt_in or "transport-belt",
              inp.x, new_y, 1, 1, defines.direction.south, nil, 0, 0)
            inp.y = new_y
          end
        end
      end
      -- Legacy template piping assumed fixed sides and could overlap belts.
      -- Keep solids; derive all fluid ports from the selected machine prototypes.
      for j=#all,first_entity,-1 do
        local t=prototypes.entity[all[j].name].type
        if t=="pipe" or t=="pipe-to-ground" then table.remove(all,j) end
      end
      if meta then meta.fluid_inputs={};meta.fluid_outputs={} end
        return true
        end)()
        local entities,logs={},{}
        for j=first_entity,#all do entities[#entities+1]=all[j] end
        for j=first_log+1,#_diag_log_buffer do logs[#logs+1]=_diag_log_buffer[j] end
        for j=#all,first_entity,-1 do all[j]=nil end
        for j=#_diag_log_buffer,first_log+1,-1 do _diag_log_buffer[j]=nil end
        return {ok=ok,entities=entities,logs=logs,en=en,height=block_h,meta=meta}
      end,true)
      generation_work.section_boundary()
      local equipped=generation_work.cached('bank-equipment',function()
      local first_log=#_diag_log_buffer
      local working=generation_work.fork('bank-template-working',shell)
      en,block_h,meta=working.en,working.height,working.meta
      for _,entity in ipairs(working.entities) do all[#all+1]=entity end
      for _,line in ipairs(working.logs) do _diag_log_buffer[#_diag_log_buffer+1]=line end
      local limits={}
      if meta and meta.recipe_node then sub_node=meta.recipe_node;physical_node=quality_flows.physical(sub_node) end
      if working.ok and meta and block_h>0 then
        meta.entity_first=first_entity;meta.entity_last=#all
        local physical_ports=fluid_planner.ports(all,{meta})
        if not meta.direct_equipment then en,limits=transfer_planner.apply(all,first_entity,meta,physical_node,settings,en,transfer_catalog,transfer_bonuses,physical_ports,_diag_log) end
      end
      local entities,logs={},{}
      for j=first_entity,#all do entities[#entities+1]=all[j] end
      for j=first_log+1,#_diag_log_buffer do logs[#logs+1]=_diag_log_buffer[j] end
      for j=#all,first_entity,-1 do all[j]=nil end
      for j=#_diag_log_buffer,first_log+1,-1 do _diag_log_buffer[j]=nil end
      return {ok=working.ok,entities=entities,logs=logs,meta=meta,en=en,height=block_h,limits=limits}
      end,true)
      generation_work.section_boundary()
      local working=generation_work.fork('bank-equipment-working',equipped)
      en,block_h,meta=working.en,working.height,working.meta
      for _,entity in ipairs(working.entities) do all[#all+1]=entity end
      for _,line in ipairs(working.logs) do _diag_log_buffer[#_diag_log_buffer+1]=line end
      if not working.ok then return false end
      if meta and meta.recipe_node then sub_node=meta.recipe_node;physical_node=quality_flows.physical(sub_node) end
      if meta and block_h>0 then
        local limits=working.limits
        if shared and mixed_beacon_bank and #limits>0 then
          for j=#all,first_entity,-1 do all[j]=nil end
          en=original_en
          return false
        end
        if settings.transfer_mode=='auto' and #limits>0 then
          for j=#all,first_entity,-1 do all[j]=nil end
          en=original_en
          if sub_count>1 then return false end
          local limit=limits[1]
          local caption=prototypes.recipe[limit.recipe] and prototypes.recipe[limit.recipe].localised_name or limit.recipe
          error({'bfh.auto-transfer-unsupported',caption,{'bfh.transfer-'..limit.side},string.format('%.3g',limit.required),string.format('%.3g',limit.capacity)},0)
        end
        if settings.transfer_mode=='loaders' and #limits>0 then
          local limit=limits[1]
          local recipe_name=prototypes.recipe[limit.recipe] and prototypes.recipe[limit.recipe].localised_name or limit.recipe
          error({'bfh.loader-layout-unsupported',recipe_name,{'bfh.transfer-'..limit.side},string.format('%.3g',limit.required),string.format('%.3g',limit.capacity)},0)
        end
        for _,limit in ipairs(limits) do
          local signature=tostring(limit.recipe)..'/'..limit.side..'/'..table.concat(limit.items,',')
          if _diag_player and not _capacity_warned[signature] then
            local names={''};for i,name in ipairs(limit.items) do if i>1 then names[#names+1]=', ' end;names[#names+1]=prototypes.item[name] and prototypes.item[name].localised_name or name end
            local recipe_name=prototypes.recipe[limit.recipe] and prototypes.recipe[limit.recipe].localised_name or limit.recipe
            _diag_player.print({'bfh.transfer-limit',recipe_name,{'bfh.transfer-'..limit.side},names,string.format('%.3g',limit.capacity),string.format('%.3g',limit.required)})
          end
          _capacity_warned[signature]=true
        end
        quality_flows.metadata(meta,sub_node)
        en=quality_flows.sort(all,first_entity,meta,sub_node,settings,en,transfer_catalog)
        en=lane_balance.attach(all,first_entity,meta,sub_count,settings,en,output_rates,to_splitter(settings.belt_out or 'transport-belt'),transfer_catalog)
        local solid=true
        for _,side in ipairs({'ingredients','products'}) do for _,v in ipairs(sub_node[side] or {}) do if v.type=='fluid' then solid=false end end end
        if solid then
          local optimized=generation_work.cached('local-surface-belts',function()
            local es={};for j=first_entity,#all do es[#es+1]=generation_work.copy(all[j]) end
            local next_id,removed=tunnel_optimizer.apply(es,en,settings)
            return {entities=es,en=next_id,removed=removed}
          end,true)
          for j,e in ipairs(optimized.entities) do all[first_entity+j-1]=generation_work.copy(e) end
          en=optimized.en
          if optimized.removed>0 then _diag_log('[BFH-block] Removed empty tunnels: '..optimized.removed..' '..sub_node.name) end
        end
        if beacon_planner.has(sub_node) then
          meta.entity_first=first_entity;meta.entity_last=#all
          local ports=fluid_planner.ports(all,{meta})
          local next_en,next_height=beacon_planner.plan(all,first_entity,meta,sub_node,en,ports,shared)
          if not next_en then
            for j=#all,first_entity,-1 do all[j]=nil end
            en=original_en
            return false
          end
          en,block_h=next_en,next_height
        end
        quality_flows.fit(all,first_entity,meta)
        block_h=math.max(block_h,meta.height or 0)
        local minx,maxx,maxy=math.huge,-math.huge,-math.huge
        for j=first_entity,#all do local e=all[j];local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
          if e.direction==4 or e.direction==12 then w,h=h,w end
          minx=math.min(minx,e.position.x-w/2);maxx=math.max(maxx,e.position.x+w/2);maxy=math.max(maxy,e.position.y+h/2)
        end
        meta.width=math.max(meta.width or 0,maxx-minx);block_h=math.max(block_h,maxy-oy)
      end
      if meta and block_h>0 then
        meta.layout_belt_capacity=math.min(belt_throughput(settings.belt_in),belt_throughput(settings.belt_out))
        meta.entity_first=first_entity;meta.entity_last=#all
        meta.machine_ids={}
        for j=first_entity,#all do if all[j].recipe or prototypes.entity[all[j].name].type=='furnace' then meta.machine_ids[#meta.machine_ids+1]=all[j].entity_number end end
        blocks_meta[#blocks_meta + 1] = meta
      end

      -- Ширина блока — нужна для следующего подблока по X. Используем мета,
      -- если в meta есть width; иначе — best-effort через "конец последней сущности".
      local block_w
      if meta and meta.width then
        block_w = meta.width
      else
        -- fallback: вычисляем по последним добавленным сущностям
        local max_x = ox
        for j = #all, 1, -1 do
          local e = all[j]
          if e.position.x > max_x then max_x = e.position.x end
          if j < #all - 100 then break end  -- защита
        end
        block_w = math.ceil(max_x - ox) + 1
      end

      ox = ox + block_w + SUBBLOCK_GAP_X
      if block_h > row_max_h then row_max_h = block_h end
      return true
    end
    local function build_bank(sub_count,ratio)
      local first,last_block,last_log=#all+1,#blocks_meta,#_diag_log_buffer
      local built=generation_work.cached('production-bank',function()
        local ok=build_bank_once(sub_count,ratio)
        local entities,blocks,logs={},{},{}
        for j=first,#all do entities[#entities+1]=all[j] end
        for j=last_block+1,#blocks_meta do blocks[#blocks+1]=blocks_meta[j] end
        for j=last_log+1,#_diag_log_buffer do logs[#logs+1]=_diag_log_buffer[j] end
        for j=#all,first,-1 do all[j]=nil end
        for j=#blocks_meta,last_block+1,-1 do blocks_meta[j]=nil end
        for j=#_diag_log_buffer,last_log+1,-1 do _diag_log_buffer[j]=nil end
        return {ok=ok,entities=entities,blocks=blocks,logs=logs,en=en,ox=ox,height=row_max_h}
      end,true)
      -- Earlier sections are occupancy only until the completed production
      -- snapshot is copied for placement. Replaying them must not deep-copy
      -- every already-built machine on every section boundary.
      for _,entity in ipairs(built.entities) do all[#all+1]=entity end
      for _,block in ipairs(built.blocks) do blocks_meta[#blocks_meta+1]=block end
      for _,line in ipairs(built.logs) do _diag_log_buffer[#_diag_log_buffer+1]=line end
      en,ox,row_max_h=built.en,built.ox,built.height
      generation_work.section_boundary()
      return built.ok
    end
    for i=1,split_count do
      local remaining=bank_counts[i]
      local rate_per_machine=bank_ratios[i]/remaining
      while remaining>0 do
        local count=remaining
        while not build_bank(count,rate_per_machine*count) do count=count-1 end
        remaining=remaining-count
      end
    end

    oy = oy + row_max_h + BLOCK_GAP
  end

  en=launch_products.apply(all,blocks_meta,settings,en,transfer_catalog,transfer_bonuses)
  return all,en,blocks_meta,_diag_log_buffer
  end
  local all,en,blocks_meta,base_logs=generation_work.cached('production-blocks',function()return production_blocks(true,true)end,true)
  local legacy_geometry,shared_beacons
  for _,b in ipairs(blocks_meta) do if b.shared_beacon then shared_beacons=true;break end end
  for _,b in ipairs(blocks_meta) do if (b.parallel_outputs or b.shared_beacon) and settings.link_mode~='independent' then
    legacy_geometry=generation_work.cached('production-blocks-legacy',function()
      local es,id,bs,logs=production_blocks(false);return {entities=es,en=id,blocks=bs,logs=logs}
    end,true)
    break
  end end
  _diag_log_buffer=generation_work.copy(base_logs)

  local function plan_external_interface(entities,blocks,ports,id,fluid_clearance)
    return external_inputs.plan(entities,blocks,ports,settings,id,fluid_clearance)
  end

  local function apply_layout(all,blocks_meta,gap,compact,dense,align_ports,flow_aware,arrays,initial_en)
    local array_options=type(arrays)=='table' and arrays or {method=arrays=='compact' and 'compact' or nil}
    local prepared=generation_work.cached('layout-footprints',function()
    local seed=generation_work.cached('layout-junctions',function()
    local source=generation_work.fork('layout-source',{entities=all,blocks=blocks_meta});all,blocks_meta=source.entities,source.blocks
    block_boundaries.freeze(all,blocks_meta)
    if arrays then local count,packed,collected;initial_en,count,packed,collected=furnace_arrays.prepare(all,blocks_meta,settings,initial_en,transfer_catalog,array_options.limit,array_options.pack);_diag_log("[BFH-array] Shared fuel feeds: "..count.."; product collectors: "..(collected or 0)) end
    local prepared_junctions;initial_en,prepared_junctions=junction_plan.apply(all,blocks_meta,settings,initial_en,export_requirements,transfer_catalog)
    _diag_log('[BFH-junctions] Preplanned resources: '..prepared_junctions)
    return {entities=all,blocks=blocks_meta,en=initial_en,logs=_diag_trial_logs}
    end,true)
    generation_work.section_boundary()
    all,initial_en=seed.entities,seed.en;_diag_trial_logs=generation_work.copy(seed.logs)
    blocks_meta=generation_work.operation('layout-footprint-blocks',nil,{entities=all,blocks=seed.blocks},true)
    local physical_ports=fluid_planner.ports(all,blocks_meta)
    if settings.link_mode~='independent' then fluid_planner.layout_clearance(blocks_meta,physical_ports) end
    for _,b in ipairs(blocks_meta) do b.layout_fluid_ports={} end
    for _,p in ipairs(physical_ports) do
      local b=blocks_meta[p.block];b.layout_fluid_ports[#b.layout_fluid_ports+1]=p
    end
    return {entities=all,blocks=blocks_meta,en=initial_en,logs=_diag_trial_logs}
    end,true)
    generation_work.section_boundary()
    all=prepared.entities;blocks_meta=generation_work.fork('layout-blocks',prepared.blocks);initial_en=prepared.en
    _diag_trial_logs=generation_work.copy(prepared.logs)
    local shifts,reason
    if arrays then shifts=furnace_arrays.place(blocks_meta,layout_planner,{gap=gap,compact=compact,align_ports=align_ports,ratio=layout_shape.ratio(settings),thorough=settings.layout_search=='thorough',boundary=orientation.output(settings),method=array_options.method,limit=array_options.limit,hierarchical=array_options.hierarchical,cluster_limit=array_options.cluster_limit,approach=array_options.approach}) elseif dense then shifts=layout_planner.dense(blocks_meta,gap,compact,align_ports,layout_shape.ratio(settings),settings.layout_search=='thorough',orientation.output(settings),flow_aware) elseif compact then shifts=layout_planner.compact(blocks_meta,gap,compact,nil,layout_shape.ratio(settings)) else shifts,reason=layout_planner.plan(blocks_meta,gap) end
    all=generation_work.fork('layout-transformed-entities',all)
    if shifts then
      local move_ports=block_boundaries.translate
      for i,b in ipairs(blocks_meta) do
        local d=shifts[i]
        if d.turn and d.turn~=0 then
          local left,top,w,h=b.layout_left,b.layout_top,b.layout_width,b.layout_height
          local function rotate(x,y)
            x,y=x-left,y-top
            local rw,rh=w,h
            for turn=1,d.turn do x,y=rh-y,x;rw,rh=rh,rw end
            return left+x,top+y
          end
          for j=b.entity_first,b.entity_last do
            local e=all[j];e.position.x,e.position.y=rotate(e.position.x,e.position.y)
            e.direction=((e.direction or 0)+d.turn*4)%16
          end
          local function rotate_port(p)
            local x,y=rotate(p.x+0.5,p.y+0.5);p.x=x-0.5;p.y=y-0.5
            if p.direction then p.direction=(p.direction+d.turn*4)%16 end
          end
          for _,p in ipairs(b.inputs or {}) do rotate_port(p) end
          if b.product_out then rotate_port(b.product_out) end
          for _,p in ipairs(b.output_ports or {}) do rotate_port(p) end
          for _,p in pairs(b.product_outs or {}) do rotate_port(p) end
          if b.mixed_output then rotate_port(b.mixed_output) end
          for _,p in ipairs(b.array_output_contacts or {}) do rotate_port(p) end
          for _,p in ipairs(b.junction_guards or {}) do rotate_port(p) end
          b.rotation=d.turn*4
        end
        for j=b.entity_first,b.entity_last do
          all[j].position.x=all[j].position.x+d.x;all[j].position.y=all[j].position.y+d.y
        end
        move_ports(b,d.x,d.y)
      end
      _diag_log("[BFH-layout] Dependency stages placed with supplier-consumer ordering")
    else _diag_log("[BFH-layout] Retained vertical placement: "..tostring(reason)) end
    container_distribution.approach(all,blocks_meta)
    return all,blocks_meta,initial_en
  end
  local interface_result,outputs_result,layout_status
  if settings.link_mode ~= "independent" then
    local copy=generation_work.copy
    local function cost(entities)
      return layout_shape.measure(entities,layout_shape.ratio(settings))
    end
    local function tunnel_issues(entities)
      return generation_work.cached('trial-tunnels',function()return ug_pairing.issues({entities})end,true)
    end
    local player=_diag_player
    local best
    local layout_options=layout_search.options(legacy_geometry~=nil,settings.layout_search,furnace_arrays.available(legacy_geometry and legacy_geometry.blocks or blocks_meta))
    local fluid_exports=0
    for _,flow in ipairs(export_requirements) do if flow.type=='fluid' then fluid_exports=fluid_exports+1 end end
    if fluid_exports>1 then
      -- A compact packing can trap fluid ports when several exports share a side.
      layout_options[#layout_options+1]={gap=2,compact=1.4,dense=true,fluid_clearance=4}
    end
    if shared_beacons and layout_options[2] then
      layout_options[1].legacy=nil
      layout_options[2].legacy=true
    end
    -- Try aligned ports before the other placements for shared banks that
    -- must route pipes as well as belts past external container distributors.
    if shared_beacons and settings.distribution_mode=='containers' and settings.layout_search~='thorough' then
      local mixed_shared_bank=false
      for _,block in ipairs(blocks_meta) do
        if block.shared_beacon and #get_fluid_ingredients(block.recipe_node)>0 then
          mixed_shared_bank=true
          break
        end
      end
      if mixed_shared_bank then
        for i,option in ipairs(layout_options) do
          if option.align_ports and not option.legacy then
            table.insert(layout_options,1,table.remove(layout_options,i))
            break
          end
        end
      end
    end
    layout_options=layout_search.unique(layout_options)
    layout_options=layout_search.fluid_first(layout_options,blocks_meta,settings.layout_search,settings.distribution_mode)
    local function count_beacons(entities)
      local count = 0
      for _, entity in ipairs(entities) do
        if prototypes.entity[entity.name].type == 'beacon' then count = count + 1 end
      end
      return count
    end
    local tried,first_valid=0,nil
    for option_index,option in ipairs(layout_options) do
      generation_work.layout_begin(option_index,layout_search.route_budget(blocks_meta,settings.layout_search))
      local fraction=0.05+(option_index-1)*0.9/#layout_options
      generation_work.phase('layout',fraction,option_index..'/'..#layout_options)
      local trial=generation_work.cached('candidate-'..option_index,function()
        local gap=option.gap
        _diag_trial=true;_diag_trial_logs={};_diag_player=nil
        -- Completed bundles are read-only on replay; modifying stages fork their input.
        local bundle=generation_work.cached('placement',function()
          local laid_out=generation_work.cached('placed-geometry',function()
          local transformed=generation_work.cached('transformed-geometry',function()
          local original=option.legacy and legacy_geometry
          local candidate,metadata=original and original.entities or all,original and original.blocks or blocks_meta
          local initial_en=original and original.en or en
          if gap~=nil then candidate,metadata,initial_en=apply_layout(candidate,metadata,gap,option.compact,option.dense,option.align_ports,option.flow_aware,option.arrays,initial_en)
          else local source=generation_work.fork('vertical-source',{entities=candidate,blocks=metadata});candidate,metadata=source.entities,source.blocks end
          return {entities=candidate,metadata=metadata,en=initial_en,logs=_diag_trial_logs}
          end,true)
          generation_work.section_boundary()
          local candidate=transformed.entities
          local metadata=generation_work.cached('captured-blocks',function()
            local blocks=generation_work.fork('capture-blocks',transformed.metadata)
            block_boundaries.capture(candidate,blocks)
            return blocks
          end,true)
          generation_work.section_boundary()
          local initial_en=transformed.en;_diag_trial_logs=generation_work.copy(transformed.logs)
          local contacts=belt_contacts.between(candidate,metadata)
          generation_work.section_boundary()
          if #contacts>0 then generation_work.pruned();return end
          local geometry={}
          for _,e in ipairs(candidate) do geometry[#geometry+1]=e.position.x..','..e.position.y..','..(e.direction or 0) end
          local signature=table.concat(geometry,';')..'/'..tostring(option.inputs_first)..'/'..tostring(option.fluid_clearance)..'/'..tostring(option.fluids_first)
          local previous=generation_work.layout_seen(signature,option_index)
          if previous then return end
          return {entities=candidate,metadata=metadata,en=initial_en,logs=_diag_trial_logs}
          end,true)
          generation_work.section_boundary()
          if not laid_out then return end
          local working=generation_work.fork('placement-interface',laid_out)
          local candidate,metadata,initial_en=working.entities,working.metadata,working.en
          _diag_trial_logs=working.logs
          local beacon_count = shared_beacons and count_beacons(candidate) or 0
          local lower_bound,lower_area=cost(candidate)
          if not layout_shape.ratio(settings) and best and best.failures==0
            and (beacon_count > best.beacon_count or (beacon_count == best.beacon_count
              and (lower_area>best.area or (lower_area==best.area and lower_bound>=best.score)))) then return end
          local ports,port_issues=fluid_planner.ports(candidate,metadata)
          local external_plan,face_x,interface_en=plan_external_interface(candidate,metadata,ports,initial_en,option.fluid_clearance)
          local routed_settings=copy(settings);routed_settings.external_face_x=face_x;routed_settings.routing_min_x=face_x and face_x+2
          for _,issue in ipairs(port_issues) do _diag_log(issue) end
          local reserved_en=fluid_planner.reserve(candidate,ports,interface_en,settings.pipe or "pipe")
          return {entities=candidate,metadata=metadata,ports=ports,port_issues=port_issues,external_plan=external_plan,settings=routed_settings,beacon_count=beacon_count,en=reserved_en,logs=_diag_trial_logs}
        end,true)
        generation_work.section_boundary()
        if bundle then
          _diag_trial_logs=bundle.logs
          generation_work.phase('outputs',fraction+0.005,option_index..'/'..#layout_options)
          bundle=generation_work.cached('final-outputs',function()
            bundle=generation_work.fork('working-bundle',bundle);_diag_trial_logs=bundle.logs
            local outputs,consumers,next_en=output_flows.plan(bundle.entities,export_requirements,bundle.settings,bundle.en,bundle.metadata)
            bundle.en=next_en;bundle.outputs=outputs;bundle.settings.output_consumers=consumers
            if fluid_exports>0 then
              local fluid_outputs=final_outputs.plan_fluids(bundle.entities,export_requirements,bundle.ports,bundle.settings)
              for _,output in ipairs(fluid_outputs) do bundle.outputs[#bundle.outputs+1]=output end
            end
            local new_ports={};for _,p in ipairs(bundle.ports) do if p.terminal then new_ports[#new_ports+1]=p end end
            bundle.en=fluid_planner.reserve(bundle.entities,new_ports,bundle.en,bundle.settings.pipe or 'pipe')
            bundle.logs=_diag_trial_logs;return bundle
          end,true)
          generation_work.section_boundary()
          local function route_fluids()
            _diag_trial_logs=bundle.logs
            local belt_clearance=generation_work.cached('fluid-belt-clearance',function()return fluid_planner.solid_clearance(bundle.entities,bundle.metadata,bundle.ports)end,true)
          generation_work.layout_begin('fluids-'..option_index,settings.layout_search~='thorough' and 240000 or nil)
          generation_work.phase('fluids',fraction+(option.fluids_first and 0.02 or 0.04),option_index..'/'..#layout_options)
          bundle=generation_work.cached('fluid-connections',function()
            -- Routing appends/removes array entries but never edits existing entities.
            -- Copy only mutable fluid inputs, not every block and route snapshot.
            local working=generation_work.fork('fluid-working',{
              entities=bundle.entities,ports=bundle.ports,settings=bundle.settings,outputs=bundle.outputs,logs=bundle.logs},bundle.entities)
            local result={};for k,v in pairs(bundle) do result[k]=v end
            result.entities=working.entities;result.ports=working.ports;result.settings=working.settings;result.outputs=working.outputs
            result.settings.fluid_belt_clearance=belt_clearance
            _diag_trial_logs=working.logs
            result.en,result.fluid_failures=fluid_planner.route(result.entities,result.ports,bundle.en,result.settings,_diag_log)
            result.logs=_diag_trial_logs;return result
          end,true)
          generation_work.section_boundary()
          end
          if option.fluids_first then route_fluids() end
          if option.inputs_first then
          generation_work.layout_begin('inputs-'..option_index,settings.layout_search~='thorough' and 240000 or nil)
          generation_work.phase('inputs',fraction+0.01,option_index..'/'..#layout_options)
          bundle=generation_work.cached('raw-connections',function()
            bundle=generation_work.fork('working-bundle',bundle,bundle.entities);_diag_trial_logs=bundle.logs
            local input_settings=copy(bundle.settings);input_settings.external_only=true;input_settings.external_plan=bundle.external_plan
            bundle.en,bundle.external_failures=connect_blocks(bundle.metadata,input_settings,bundle.en,bundle.entities)
            bundle.logs=_diag_trial_logs;return bundle
          end,true)
          generation_work.section_boundary()
          _diag_trial_logs=bundle.logs
          generation_work.layout_begin(option_index,layout_search.route_budget(bundle.metadata,settings.layout_search))
          end
          generation_work.layout_begin(option_index,layout_search.route_budget(bundle.metadata,settings.layout_search))
          generation_work.phase('belts',fraction+(option.fluids_first and 0.04 or 0.02),option_index..'/'..#layout_options)
          bundle=generation_work.cached('solid-connections',function()
            bundle=generation_work.fork('working-bundle',bundle,bundle.entities);_diag_trial_logs=bundle.logs
            local id,failures,result=connect_blocks(bundle.metadata,bundle.settings,bundle.en,bundle.entities,bundle)
            bundle=result or bundle;bundle.en=id;bundle.failures=failures
            bundle.logs=_diag_trial_logs;return bundle
          end,true)
          generation_work.section_boundary()
          if best and (bundle.failures or 0)+#bundle.port_issues>best.failures then generation_work.pruned();return end
          _diag_trial_logs=bundle.logs
          if not option.fluids_first then route_fluids() end
          _diag_trial_logs=bundle.logs
          if best and (bundle.failures or 0)+bundle.fluid_failures+#bundle.port_issues>best.failures then generation_work.pruned();return end
          if not option.inputs_first then
            generation_work.layout_begin('inputs-'..option_index,settings.layout_search~='thorough' and 240000 or nil)
            generation_work.phase('inputs',fraction+0.055,option_index..'/'..#layout_options)
            bundle=generation_work.cached('late-inputs',function()
              bundle=generation_work.fork('working-bundle',bundle,bundle.entities);_diag_trial_logs=bundle.logs
              bundle.settings.external_only=true;bundle.settings.external_plan=bundle.external_plan
              bundle.en,bundle.external_failures=connect_blocks(bundle.metadata,bundle.settings,bundle.en,bundle.entities)
              bundle.logs=_diag_trial_logs;return bundle
            end,true)
            generation_work.section_boundary()
            _diag_trial_logs=bundle.logs
          end
          generation_work.layout_begin('outputs-'..option_index,settings.layout_search~='thorough' and 240000 or nil)
          generation_work.phase('outputs',fraction+0.065,option_index..'/'..#layout_options)
          bundle=generation_work.cached('output-connections',function()
            bundle=generation_work.fork('working-bundle',bundle,bundle.entities);_diag_trial_logs=bundle.logs
            local candidate=bundle.entities
            for i=#candidate,1,-1 do if candidate[i].tags and candidate[i].tags.bfh_external_reservation then table.remove(candidate,i) end end
            local output_settings=copy(bundle.settings);output_settings.external_only=false;output_settings.outputs_only=true;output_settings.belt_in=output_settings.belt_out;output_settings.routing_max_x=bundle.output_face_x
            if orientation.output(settings)==12 then
              for _,p in ipairs(bundle.outputs or {}) do output_settings.routing_min_x=math.min(output_settings.routing_min_x or p.x,p.x) end
            end
            local id,failures=connect_blocks(bundle.metadata,output_settings,bundle.en,candidate)
            bundle.en=id;bundle.output_failures=failures;bundle.logs=_diag_trial_logs
            return bundle
          end,true)
          generation_work.section_boundary()
          -- Validation may append diagnostics while its searches are suspended.
          -- Keep those messages out of the immutable routing snapshot.
          _diag_trial_logs=copy(bundle.logs)
          local candidate,metadata,final_en=bundle.entities,bundle.metadata,bundle.en
          local failures=(bundle.failures or 0)+(bundle.output_failures or 0)+bundle.fluid_failures+#bundle.port_issues+(bundle.external_failures or 0)
          local invalid_tunnels=tunnel_issues(candidate)
          if invalid_tunnels>0 then _diag_log('[BFH-tunnel] FAIL incompatible underground mouths: '..invalid_tunnels) end
          failures=failures+invalid_tunnels
          local physical_issues=belt_validator.check(candidate,metadata,external_inputs.interface(bundle.external_plan),false,bundle.outputs)
          failures=failures+#physical_issues
          for _,issue in ipairs(physical_issues) do _diag_log('[BFH-trial-validation] '..issue) end
          local output_issues=belt_validator.links(candidate,final_outputs.demands(bundle.outputs))
          failures=failures+#output_issues
          for _,issue in ipairs(output_issues) do _diag_log('[BFH-output-validation] '..issue) end
          local allocation_issues=output_flows.issues(metadata,bundle.outputs)
          failures=failures+#allocation_issues
          for _,issue in ipairs(allocation_issues) do _diag_log('[BFH-flow-validation] '..issue) end
          local score,area,shape_rank=cost(candidate)
          log('[BFH-candidate] '..option_index..' failures='..failures..' entities='..#candidate)
          return {entities=candidate,blocks=metadata,en=final_en,failures=failures,beacon_count=bundle.beacon_count,logs=_diag_trial_logs,legacy=option.legacy,gap=gap,compact=option.compact,dense=option.dense,score=score,area=area,shape_rank=shape_rank,interface=bundle.external_plan,outputs=bundle.outputs}
        end
      end,true)
      _diag_trial=false;_diag_player=player;_diag_trial_logs=nil
      generation_work.section_boundary()
      if trial and (not best or trial.failures < best.failures
        or (trial.failures == best.failures and (trial.beacon_count < best.beacon_count
          or (trial.beacon_count == best.beacon_count and (trial.shape_rank < best.shape_rank
            or (trial.shape_rank == best.shape_rank and trial.score < best.score)))))) then
        best = trial
      end
      tried=option_index
      if best and best.failures==0 and not first_valid then first_valid=option_index end
      if layout_search.done(settings.layout_search,first_valid,option_index) then break end
    end
    generation_work.layout_end()
    if not best then error({'bfh.layout-no-candidate'},0) end
    layout_status={tried=tried,limit=#layout_options,early=tried<#layout_options,mode=settings.layout_search or 'normal',failures=best.failures}
    _diag_log_buffer=generation_work.copy(best.legacy and legacy_geometry.logs or base_logs)
    _diag_log('[BFH-layout] Search '..layout_status.mode..': '..tried..'/'..#layout_options..'; early='..tostring(layout_status.early))
    _diag_log('[BFH-output-layout] Selected '..(best.legacy and 'legacy' or 'parallel-capable')..' production topology')
    all,blocks_meta,en=best.entities,best.blocks,best.en
    interface_result=external_inputs.interface(best.interface);outputs_result=best.outputs
    _diag_log("[BFH-layout] Selected placement: "..(best.gap and ((best.dense and "dense rotated packing" or best.compact and "compact packing" or "dependency stages")..", gap="..best.gap) or "vertical fallback").."; area="..best.area.."; score="..best.score)
    local rotated=0;for _,b in ipairs(blocks_meta) do if (b.rotation or 0)~=0 then rotated=rotated+1 end end
    _diag_log("[BFH-layout] Rotated blocks: "..rotated)
    for _,message in ipairs(best.logs) do _diag_log(message) end
    if player and best.failures>0 then player.print({"bfh.routing-incomplete",best.failures}) end
  end

  if settings.link_mode=="independent" then
    generation_work.phase("independent-fluids",0.4)
    local independent=generation_work.cached('independent-connections',function()
      local source=generation_work.fork('independent-source',{entities=all,blocks=blocks_meta});local entities,blocks=source.entities,source.blocks
      local id,failures,complete=fluid_planner.independent(entities,blocks,en,settings,_diag_log,BLOCK_GAP)
      return {entities=complete,blocks=blocks,en=id,failures=failures,logs=generation_work.copy(_diag_log_buffer)}
    end,true)
    generation_work.section_boundary()
    all,blocks_meta,en=independent.entities,independent.blocks,independent.en
    _diag_log_buffer=generation_work.copy(independent.logs)
    if _diag_player and independent.failures>0 then _diag_player.print({"bfh.routing-incomplete",independent.failures}) end
  end
  generation_work.phase("finishing",0.98)
  local function finished_fluid_ports(entities)
    local ports=fluid_planner.ports(entities,blocks_meta)
    for _,input in ipairs(interface_result or {}) do if input.type=='fluid' then ports[#ports+1]={x=input.x,y=input.y,dir=input.direction or 4,fluid=input.name,kind='output',external=true,block=0} end end
    for _,output in ipairs(outputs_result or {}) do if output.type=='fluid' then ports[#ports+1]={x=output.x,y=output.y,dir=((output.direction or 4)+8)%16,fluid=output.name,kind='input',external=true,rate=output.rate,block=0} end end
    return ports
  end
  local fmf_status
  if fmf_catalog then
    generation_work.phase('fmf',0.981)
    local promoted=generation_work.cached('fmf-geometry',function()
      local entities,id,status=fmf.promote(all,finished_fluid_ports(all),en,settings,fmf_catalog)
      if status.skipped.invalid then error({'bfh.fmf-base-invalid'},0) end
      return {entities=entities,en=id,status=status}
    end,true)
    all,en,fmf_status=promoted.entities,promoted.en,promoted.status
  end
  local prepared=generation_work.cached('final-geometry',function()
  local labelled=generation_work.cached('labelled-geometry',function()
  local source=generation_work.fork('final-source',{entities=all,blocks=blocks_meta,inputs=interface_result,outputs=outputs_result})
  all,blocks_meta,interface_result,outputs_result=source.entities,source.blocks,source.inputs,source.outputs
  if settings.distribution_mode=='containers' then
    local buffered=container_distribution.regulate(all,blocks_meta,settings)
    _diag_log('[BFH-container] Buffered branches: '..buffered)
  end
  if settings.use_display_plates then
    if display_plates.available() then
      local _,missing=display_plates.add(all,blocks_meta,interface_result,settings,to_underground,_diag_log)
      if missing>0 and _diag_player then _diag_player.print({'bfh.display-plates-missing',missing}) end
    elseif _diag_player then _diag_player.print({'bfh.display-plates-unavailable'}) end
  end
  return source
  end,true)
  generation_work.section_boundary()
  local source=labelled
  for _,output in ipairs(labelled.outputs or {}) do
    if (output.internal_rate or 0)>0 then
      source=generation_work.fork('priority-geometry',labelled)
      final_outputs.prioritize_fluids(source.entities,source.outputs,source.blocks,transfer_catalog.items,fmf_catalog)
      break
    end
  end
  all,blocks_meta,interface_result,outputs_result=source.entities,source.blocks,source.inputs,source.outputs
  local ports=finished_fluid_ports(all)
  return {entities=all,interface=interface_result,ports=ports,blocks=blocks_meta,outputs=outputs_result}
  end,true)
  generation_work.section_boundary()
  generation_work.phase('power',0.985)
  local powered=generation_work.cached('electrification',function()
    local poles,status=power_planner.plan(prepared.entities,game.forces[settings.force_name or 'player'],settings,prepared.interface,prepared.outputs,transfer_catalog.items)
    local entities=generation_work.fork('powered-entities',prepared.entities)
    for _,pole in ipairs(poles) do entities[#entities+1]=pole end
    return {entities=entities,status=status}
  end,true)
  generation_work.section_boundary()
  all,interface_result=transport_quality.apply(powered.entities,settings.transport_quality),prepared.interface
  local validation_issues=validator.fluids(all,prepared.ports,settings.link_mode=='independent')
  local belt_issues=belt_validator.check(all,prepared.blocks,interface_result,settings.link_mode=='independent',prepared.outputs)
  for _,issue in ipairs(belt_issues) do validation_issues[#validation_issues+1]=issue end
  for i,detail in ipairs(belt_issues.machine_details or {}) do
    if i>5 then break end
    local item=prototypes.item[resources.name(detail.name)];local machine=prototypes.entity[detail.machine];local recipe=prototypes.recipe[detail.recipe]
    if _diag_player then _diag_player.print({detail.output and 'bfh.machine-output-disconnected' or 'bfh.machine-feed-disconnected',item and item.localised_name or detail.name,machine and machine.localised_name or detail.machine,recipe and recipe.localised_name or detail.recipe,detail.x,detail.y}) end
  end
  local output_issues=belt_validator.links(all,final_outputs.demands(prepared.outputs))
  for _,issue in ipairs(output_issues) do validation_issues[#validation_issues+1]=issue end
  for _,issue in ipairs(output_flows.issues(prepared.blocks,prepared.outputs)) do validation_issues[#validation_issues+1]=issue end
  validation_issues.beacon_details=beacon_planner.validate(all,prepared.blocks)
  for _,v in ipairs(validation_issues.beacon_details) do
    validation_issues[#validation_issues+1]='Beacon effect mismatch: '..v.recipe..' at '..v.x..','..v.y
  end
  validation_issues.material_details=belt_issues.material_details
  validation_issues.beacons=beacon_planner.counts(all,recipes)
  for _,c in ipairs(validation_issues.beacons) do
    if c.known and c.actual~=c.estimated and _diag_player then
      _diag_player.print({'bfh.beacon-count-difference',prototypes.entity[c.name].localised_name,c.estimated,c.actual})
    end
  end
  validation_issues.power=powered.status
  if powered.status.unavailable then validation_issues[#validation_issues+1]='No researched supported electric pole available' end
  if (powered.status.uncovered or 0)>0 then validation_issues[#validation_issues+1]='Electricity coverage missing for '..powered.status.uncovered..' entities' end
  if (powered.status.components or 0)>1 then validation_issues[#validation_issues+1]='Disconnected electricity networks: '..powered.status.components end
  validation_issues.outputs=prepared.outputs
  validation_issues.layout_search=layout_status
  validation_issues.fmf=fmf_status
  if fmf_status then
    _diag_log('[BFH-FMF] Bridges='..fmf_status.bridges..'; ordinary='..fmf_status.ordinary)
    if _diag_player then _diag_player.print({'bfh.fmf-summary',fmf_status.bridges,fmf_status.ordinary}) end
  end
  local plan_summary=plan_validator.summary(recipes)
  validation_issues.rate_limits=plan_summary.deficits
  validation_issues.imports=plan_summary.imports
  validation_issues.unknown_rates=plan_summary.unknown
  validation_issues.auto_equipment=auto_equipment
  local lane_changes=lane_balance.inserter_lanes(all,prepared.outputs,prepared.blocks)
  for _,limit in ipairs(validation_issues.rate_limits) do
    _diag_log('[BFH-plan] '..limit.name..': '..limit.produced..'/s; required '..limit.needed..'/s; shortfall '..limit.shortfall..'/s')
    local proto=(limit.type=='fluid' and prototypes.fluid or prototypes.item)[resources.name(limit.name)]
    if _diag_player then _diag_player.print({'bfh.plan-rate-limit',limit.type=='fluid' and (proto and proto.localised_name or limit.name) or resources.caption(limit.name),string.format('%.3g',limit.produced),string.format('%.3g',limit.needed),string.format('%.3g',limit.shortfall)}) end
  end
  for _,issue in ipairs(validation_issues) do _diag_log('[BFH-validation] '..issue) end
  if #validation_issues>0 and _diag_player then _diag_player.print({'bfh.validation-issues',#validation_issues}) end
  if layout_status and layout_status.mode~='thorough' and (layout_status.failures>0 or #validation_issues>0) and _diag_player then _diag_player.print({'bfh.layout-search-exhausted'}) end
  -- Сбрасываем накопленный лог в файл script-output/bfh-routing.log
  _diag_log_flush()

  for _,change in ipairs(lane_changes) do all[change.i].drop_position=change.drop end
  entity_blacklist.validate_entities(all,settings)
  orientation.finish(all,interface_result,validation_issues.outputs,settings)
  launch_products.align_entities(all,interface_result,validation_issues.outputs)
  resources.decode(interface_result);resources.decode(validation_issues.outputs)
  return all,interface_result,validation_issues
end

local function reset_generation_diagnostics()
  _diag_player=nil;_diag_trial=false;_diag_trial_logs=nil;_diag_log_buffer=nil
end

local function discard_generation()
  local job=storage.bfh_generation
  if job and job.inventory and job.inventory.valid then job.inventory.destroy() end
  storage.bfh_generation=nil
  reset_generation_diagnostics()
end

local function deliver_blueprint(player,job)
  if job.description_request then return false end
  if not player.cursor_stack or not player.clear_cursor() then return false end
  if not player.cursor_stack.transfer_stack(job.inventory[1]) then return false end
  player.print({"bfh.blueprint-created",job.entity_count})
  discard_generation()
  return true
end

local function generate_blueprint(player, recipes, settings)
  local conflict=entity_blacklist.check(settings,recipes)
  if conflict then player.print(conflict);return end
  if #recipes==0 then player.print({"bfh.no-recipes"});return end
  for _,recipe in ipairs(recipes) do
    local machine=type(recipe.factory)=='table' and recipe.factory.name
    if not entity_exists(machine) then
      player.print({'bfh.helmod-machine-unavailable',recipe.name or '?',machine or '?'})
      return
    end
  end
  local current=storage.bfh_generation
  if current then
    player.print({current.player_index==player.index and 'bfh.generation-already-running' or 'bfh.generation-busy'})
    return
  end
  local prepared,inputs=pcall(generation_work.recipe_inputs,recipes)
  if not prepared then player.print({'bfh.generation-failed',type(inputs)=='table' and inputs or tostring(inputs)});return end
  settings.launch_pad_name='BFH '..player.index..'-'..game.tick
  storage.bfh_generation={player_index=player.index,recipes=inputs,settings=generation_work.copy(settings),cache={},started_tick=game.tick,last_notice=game.tick}
  player.print({'bfh.generation-started'})
end

-- Joining peers run on_load independently of the host. Never let a flag set
-- there trigger print() or any other game-state change on a subsequent tick.
-- The join event is delivered to every peer at the same simulation tick.
script.on_event(defines.events.on_player_joined_game,function(event)
  local job=storage.bfh_generation
  if not job or not job.cache or event.player_index~=job.player_index then return end
  local owner=game.get_player(job.player_index)
  if owner and owner.valid and owner.connected then
    owner.print({'bfh.generation-resumed',job.cache.detail or '',math.floor((game.tick-job.started_tick)/60)})
  end
end)
local function advance_generation()
  local job=storage.bfh_generation
  if not job then return end
  if job.inventory then
    if job.description_request and game.tick-(job.description_started or game.tick)>=600 then
      local owner=game.get_player(job.player_index)
      if owner and owner.connected then job.description_request=owner.request_translation(job.description_document);job.description_started=game.tick end
    end
    return
  end
  local player=game.get_player(job.player_index)
  if not player or not player.valid then discard_generation();return end
  if not job.completed then
    generation_work.begin(job.cache,generation_work.load_budget(job.settings.generation_load))
    _diag_player=player
    local ok,entities,interface,validation_issues=pcall(function()
      generation_work.resume_pending()
      generation_work.replay()
      return build_blueprint_entities(job.recipes,job.settings,job.auto_equipment_retry)
    end)
    generation_work.finish()
    reset_generation_diagnostics()
    if not ok then
      if generation_work.is_pending(entities) then
        if not job.progress_announced or game.tick-(job.last_notice or job.started_tick)>=progress_notice.ticks(job.settings.notice_interval) then
          job.progress_announced=true
          job.last_notice=game.tick
          player.print({'bfh.generation-progress',{'bfh.generation-phase-'..(job.cache.phase or 'blocks')},job.cache.detail or '',math.floor((game.tick-job.started_tick)/60)})
        end
        return
      end
      log('[BFH] Generation failed: '..tostring(entities))
      discard_generation()
      player.print({'bfh.generation-failed',type(entities)=='table' and entities or tostring(entities)})
      return
    end
    local choice=validation_issues.auto_equipment
    if not job.auto_equipment_retry and capacity_planner.retry_belts(choice,validation_issues) then
      job.auto_equipment_retry=true
      job.auto_equipment_first={entities=entities,interface=interface,issues=validation_issues}
      job.cache={}
      return
    end
    local first=job.auto_equipment_first
    if first and #first.issues<=#validation_issues
      and #(first.issues.beacon_details or {})==0 and #(first.issues.material_details or {})==0 then
      entities,interface,validation_issues=first.entities,first.interface,first.issues
    end
    job.auto_equipment_first=nil
    if validation_issues.beacon_details and #validation_issues.beacon_details>0 then
      discard_generation();player.print({'bfh.beacon-effects-unsafe'});return
    end
    if validation_issues.material_details and #validation_issues.material_details>0 then
      discard_generation();player.print({'bfh.unsafe-materials'});return
    end
    job.completed={entities=entities,interface=interface,issues=validation_issues}
    job.cache=nil
    return
  end
  local entities,interface,validation_issues=job.completed.entities,job.completed.interface,job.completed.issues
  -- Only commit the finished result. The player's cursor stays untouched during work.
  local committed,err=pcall(function()
    if #entities==0 then error('empty blueprint') end
    job.inventory=game.create_inventory(1)
    local blueprint=job.inventory[1];blueprint.set_stack{name='blueprint'}
    blueprint.set_blueprint_entities(entities)
    launch_products.align_blueprint(blueprint)
    blueprint_text.apply(blueprint,blueprint_text.fallback(player.locale or 'en',job.settings,interface,validation_issues))
    local document=blueprint_text.document(job.settings,interface,validation_issues)
    if player.request_translation then
      job.description_document=document;job.description_started=game.tick
      job.description_request=player.request_translation(document)
    end
    job.entity_count=#entities;job.cache=nil;job.recipes=nil;job.settings=nil
    job.completed=nil
    if not job.description_request and not deliver_blueprint(player,job) then player.print({'bfh.generation-ready'}) end
  end)
  if not committed then
    log('[BFH] Blueprint commit failed: '..tostring(err));discard_generation()
    player.print({'bfh.generation-failed',tostring(err)})
  end
end

script.on_event(defines.events.on_string_translated,function(event)
  local job=storage.bfh_generation
  if not job or not job.inventory or job.description_request~=event.id or job.player_index~=event.player_index then return end
  if event.translated then blueprint_text.apply(job.inventory[1],event.result) end
  job.description_request=nil;job.description_document=nil;job.description_started=nil
  local player=game.get_player(job.player_index)
  if player and player.valid and not deliver_blueprint(player,job) then player.print({'bfh.generation-ready'}) end
end)

commands.add_command('bfh-cancel',{'bfh.generation-cancel-help'},function(command)
  local player=command.player_index and game.get_player(command.player_index)
  local job=storage.bfh_generation
  if player and job and job.player_index==player.index then
    discard_generation();player.print({'bfh.generation-cancelled'})
  elseif player then player.print({'bfh.generation-none'}) end
end)
commands.add_command('bfh-take',{'bfh.generation-take-help'},function(command)
  local player=command.player_index and game.get_player(command.player_index)
  local job=storage.bfh_generation
  if player and job and job.player_index==player.index and job.inventory then
    if not deliver_blueprint(player,job) then player.print({'bfh.generation-ready'}) end
  elseif player then player.print({'bfh.generation-none'}) end
end)
script.on_event(defines.events.on_tick,advance_generation)

-- Removed owners cannot retrieve/cancel their retained blueprint. Release it.
script.on_event(defines.events.on_player_removed,function(event)
  local job=storage.bfh_generation
  if job and job.player_index==event.player_index then discard_generation() end
end)

-- ── GUI (без изменений) ──────────────────────────────────────

local function destroy_gui(p)
  local f = p.gui.screen[GUI_NAME]
  if f and f.valid then f.destroy() end
end

local function get_dd(frame,name)
  return gui_layout.find(frame,name)
end

local transfer_modes={'multiple','faster','loaders','auto','auto_equipment'}
local function update_equipment_controls(frame,mode)
  local manual=mode~='auto_equipment'
  for _,name in ipairs({'bfh_belt_in','bfh_belt_out','bfh_inserter_in','bfh_inserter_out','bfh_loader'}) do
    local choice=get_dd(frame,name)
    if choice then choice.enabled=manual and (mode~='auto' or (name~='bfh_inserter_in' and name~='bfh_inserter_out')) and #choice.tags.names>(name=='bfh_loader' and 1 or 0) end
  end
  local explanation=get_dd(frame,'bfh_policy_explanation')
  if explanation then explanation.caption={'bfh.policy-help-'..(mode or 'multiple')} end
end

-- Преобразует raw-имена прототипов сущностей (например "transport-belt") в
-- список локализованных строк для отображения в drop-down. Каждый элемент списка
-- становится {"entity-name.<name>"} — Factorio подставит локализованное название.
-- Также возвращает сами raw-имена в том же порядке (для маппинга selected_index→name).
local function localized_items(raw_names)
  local items, names = {}, {}
  for i, n in ipairs(raw_names) do
    items[i] = equipment_caption.make(n)
    names[i] = n
  end
  return items, names
end

local function add_dropdown_row(parent, cap, n, raw_items, sel)
  local items, _ = localized_items(raw_items)
  local row = parent.add{ type="flow", direction="horizontal" }
  row.style.vertical_align = "center"
  row.style.bottom_margin = 4
  row.add{ type="label", caption=cap }.style.width = 140
  local dd = row.add{ type="drop-down", name=n, items=items, selected_index=#items>0 and sel or 0, enabled=#items>0 }
  dd.style.width = 300
  dd.tags={names=raw_items}
  return dd
end

local function update_side_controls(frame,s)
  local connected=s.link_mode~='independent'
  for _,name in ipairs({'bfh_layout_shape','bfh_layout_search','bfh_distribution'}) do local e=get_dd(frame,name);if e then e.enabled=connected end end
  local container=get_dd(frame,'bfh_container');if container then container.enabled=connected and s.distribution_mode=='containers' and #container.tags.names>1 end
  local help=get_dd(frame,'bfh_independent_layout_help');if help then help.visible=not connected end
  local shape_help=get_dd(frame,'bfh_shape_help');if shape_help then shape_help.visible=connected end
  local arrows={[0]='↑',[4]='→',[8]='↓',[12]='←'}
  for _,kind in ipairs({'input','output'}) do
    local selected=s[kind..'_side'] or (kind=='input' and 12 or 4)
    for side,arrow in pairs(arrows) do local b=get_dd(frame,'bfh_'..kind..'_side_'..side)
      if b then b.caption=side_preview.arrow(kind,side);b.toggled=selected==side;b.enabled=s.link_mode~='independent' end
    end
  end
  side_preview.update(frame,s)
end

local function model_owned_by(model,player)
  return type(model)=='table' and type(model.owner)=='string' and model.owner==player.name
end

local function build_gui(player)
  destroy_gui(player)
  if not helmod_available() then player.print({"bfh.helmod-missing"}) return end
  local ok, models = pcall(remote.call, "helmod_interface", "get_models")
  if not ok or not models then player.print({"bfh.helmod-no-models"}) return end
  local ml = {}
  for id, m in pairs(models) do if model_owned_by(m,player) then
    -- Иконка чертежа = иконка первого "содержательного" child в block_root.
    local sprite = nil
    local ok2, root = pcall(function() return m.block_root end)
    if ok2 and root and root.children then
      local first_name = nil
      -- Рекурсивный поиск первого child с .name (рецепт, ресурс, энергия и т.п.)
      local function find_first_named(node, depth)
        if depth > 5 then return end
        for _, child in pairs(node.children or {}) do
          if child then
            if child.name and (child.class ~= "Block" or first_name == nil) then
              -- Берём first item с именем, но если это сам Block — спускаемся глубже
              if child.class == "Block" then
                find_first_named(child, depth + 1)
                if first_name then return end
              else
                first_name = child.name
                return
              end
            end
          end
        end
      end
      find_first_named(root, 0)
      if first_name then
        -- Helmod-recipe-name может быть с префиксом (напр. "helmod-fake-...").
        -- Пробуем как recipe, item, fluid, entity (ресурс).
        if prototypes.recipe and prototypes.recipe[first_name] then
          sprite = "recipe/" .. first_name
        elseif prototypes.item and prototypes.item[first_name] then
          sprite = "item/" .. first_name
        elseif prototypes.fluid and prototypes.fluid[first_name] then
          sprite = "fluid/" .. first_name
        elseif prototypes.entity and prototypes.entity[first_name] then
          sprite = "entity/" .. first_name
        end
        _diag_log(string.format("[BFH-gui] model %s: first_name='%s' sprite='%s'",
          tostring(id), tostring(first_name), tostring(sprite)))
      end
    end
    local model_name=m.name
    if not model_name or (type(model_name)=='string' and model_name:match('^model_%d+$')) then
      local kind,name=(sprite or ''):match('^([^/]+)/(.+)$')
      local prototype=kind and prototypes[kind] and prototypes[kind][name]
      model_name=prototype and prototype.localised_name or {'bfh.plan-number',tostring(id)}
    end
    ml[#ml+1] = { id=id, name=model_name, sprite=sprite,
                  blocks=collect_blocks(m) }
  end
  end
  if #ml == 0 then player.print({"bfh.helmod-own-empty"}) return end

  local s = get_settings(player.index)
  local frame = player.gui.screen.add{
    type="frame", name=GUI_NAME, caption={"bfh.title"}, direction="vertical"
  }
  frame.auto_center = true
  player.opened = frame

  local pages=gui_layout.tabs(frame,player)
  entity_blacklist.build(pages.exclusions,s)
  local sc=pages.plans
  gui_layout.note(sc,'plans-help')

  for _, e in ipairs(ml) do
    -- Строка модели целиком (построить всю линию)
    local card=sc.add{type="frame",direction="vertical",caption=e.name}
    card.style.horizontally_stretchable=true
    local row = card.add{ type="flow", direction="horizontal" }
    row.style.vertical_align = "center"
    local icon_ok = false
    if e.sprite then
      local ok_icon, _ = pcall(function()
        local sp = row.add{ type="sprite", sprite=e.sprite }
        sp.style.width = 40
        sp.style.height = 40
        sp.style.right_margin = 6
        return sp
      end)
      icon_ok = ok_icon
    end
    if not icon_ok then
      local ph = row.add{ type="empty-widget" }
      ph.style.width = 40
      ph.style.height = 40
      ph.style.right_margin = 6
    end
    local title=row.add{ type="label", caption={"bfh.whole-line"}, style="bold_label" }
    title.style.width=270
    local b = row.add{
      type="button", caption={"bfh.generate"}, style="green_button",
      tags={ action="bfh_generate", model_id=e.id }
    }
    b.style.minimal_width = 140
    b.style.left_margin = 16

    -- Под-блоки модели — в 2 колонки, каждый: иконка вплотную к своей кнопке.
    if e.blocks and #e.blocks > 0 then
      local tbl = card.add{ type="table", column_count=1 }
      tbl.style.left_margin = 24
      tbl.style.top_margin = 4
      tbl.style.bottom_margin = 6
      tbl.style.horizontal_spacing = 16
      tbl.style.vertical_spacing = 4
      for _, blk in ipairs(e.blocks) do
        local cell = tbl.add{ type="flow", direction="horizontal" }
        cell.style.vertical_align = "center"
        -- Обёртка иконки фиксированной ширины — чтобы кнопки всех строк начинались
        -- на одном уровне независимо от ширины иконки.
        local iconbox = cell.add{ type="flow", direction="horizontal" }
        iconbox.style.width = 40
        iconbox.style.height = 32
        iconbox.style.vertical_align = "center"
        iconbox.style.horizontal_align = "center"
        iconbox.style.right_margin = 6
        local bok = false
        if blk.sprite then
          local ok_i, _ = pcall(function()
            local sp = iconbox.add{ type="sprite", sprite=blk.sprite }
            sp.style.width = 32
            sp.style.height = 32
            return sp
          end)
          bok = ok_i
        end
        if not bok then
          iconbox.add{ type="empty-widget" }
        end
        local block_name=prototypes.recipe[blk.name] and prototypes.recipe[blk.name].localised_name or tostring(blk.name)
        local block_label=cell.add{type="label",caption=block_name,tooltip={"bfh.block-recipes",blk.recipe_count}}
        block_label.style.width=270;block_label.style.single_line=false
        local bb = cell.add{
          type="button", caption={"bfh.build-block"},
          tags={ action="bfh_generate", model_id=e.id, block_id=blk.id }
        }
        bb.style.minimal_width = 100
        bb.style.height = 32
      end
    end
  end

  local sf=pages.equipment
  gui_layout.note(sf,'equipment-help')
  local equipment=transfer_planner.catalog(player.force)
  local INSERTER_ITEMS=equipment.inserters
  if #INSERTER_ITEMS==0 then INSERTER_ITEMS={"inserter"} end
  local BELT_ITEMS = get_belt_items(player.force)
  add_dropdown_row(sf, {"bfh.belt-in"},      "bfh_belt_in",      BELT_ITEMS,     idx_of(BELT_ITEMS,     s.belt_in))
  add_dropdown_row(sf, {"bfh.belt-out"},     "bfh_belt_out",     BELT_ITEMS,     idx_of(BELT_ITEMS,     s.belt_out))
  add_dropdown_row(sf, {"bfh.inserter-in"},  "bfh_inserter_in",  INSERTER_ITEMS, idx_of(INSERTER_ITEMS, s.inserter_in))
  add_dropdown_row(sf, {"bfh.inserter-out"}, "bfh_inserter_out", INSERTER_ITEMS, idx_of(INSERTER_ITEMS, s.inserter_out))
  local quality_names=transport_quality.available(player.force)
  local quality_items={};local quality_index=1
  for i,name in ipairs(quality_names) do
    quality_items[i]=transport_quality.caption(name)
    if name==(s.transport_quality or 'normal') then quality_index=i end
  end
  local quality_row=sf.add{type='flow',direction='horizontal'}
  quality_row.add{type='label',caption={'bfh.transport-quality'}}.style.width=140
  local quality_choice=quality_row.add{type='drop-down',name='bfh_transport_quality',items=quality_items,
    selected_index=quality_index,tags={names=quality_names},tooltip={'bfh.transport-quality-help'}}
  quality_choice.style.width=300
  local policy_row=sf.add{type='flow',direction='horizontal'}
  policy_row.add{type='label',caption={'bfh.transfer-policy'}}.style.width=140
  local policy_index=1
  for i,name in ipairs(transfer_modes) do if name==s.transfer_mode then policy_index=i end end
  local policy=policy_row.add{type='drop-down',name='bfh_transfer_mode',items={{'bfh.transfer-multiple'},{'bfh.transfer-faster'},{'bfh.transfer-loaders'},{'bfh.transfer-auto'},{'bfh.transfer-auto-equipment'}},selected_index=policy_index}
  policy.style.width=300;policy.tooltip={'bfh.transfer-tooltip'}
  local loader_names={'auto'};local loader_items={{'bfh.transfer-loader-auto'}};local loader_index=1
  for _,name in ipairs(equipment.loaders) do
    local p=prototypes.entity[name];local item=equipment.place_items[name]
    loader_names[#loader_names+1]=name;loader_items[#loader_items+1]={'','[item='..item..'] ',prototypes.item[item].localised_name,' — ',{'bfh.items-per-second',string.format('%g',p.belt_speed*480)}}
    if name==s.loader_name then loader_index=#loader_names end
  end
  local loader_row=sf.add{type='flow',direction='horizontal'}
  loader_row.add{type='label',caption={'bfh.transfer-loader'}}.style.width=140
  local loader=loader_row.add{type='drop-down',name='bfh_loader',items=loader_items,selected_index=loader_index,tags={names=loader_names},enabled=#equipment.loaders>0,tooltip=#equipment.loaders>0 and {'bfh.transfer-loader-tooltip'} or {'bfh.transfer-no-loaders'}}
  loader.style.width=300
  local explanation=sf.add{type='label',name='bfh_policy_explanation',caption={'bfh.policy-help-'..(s.transfer_mode or 'multiple')}}
  explanation.style.single_line=false;explanation.style.maximal_width=510
  update_equipment_controls(frame,s.transfer_mode)
  gui_layout.note(pages.generation,'generation-help')
  gui_layout.note(pages.generation,'helmod-equipment-help')
  local reserve_row=pages.generation.add{type='flow',direction='horizontal'}
  reserve_row.add{type='label',caption={'bfh.reserve-label'}}.style.width=140
  local reserve_index=({[0]=1,[5]=2,[10]=3,[20]=4})[production_reserve.percent(s.reserve_percent)]
  local reserve_choice=reserve_row.add{type='drop-down',name='bfh_reserve',items={{'bfh.reserve-exact'},'+5%','+10%','+20%'},selected_index=reserve_index}
  reserve_choice.style.width=300;reserve_choice.tooltip={'bfh.reserve-tooltip'}
  local load_row=pages.generation.add{type='flow',direction='horizontal'}
  load_row.add{type='label',caption={'bfh.generation-load'}}.style.width=140
  local load_index=({minimal=1,normal=2,fast=3})[s.generation_load] or 2
  local load_choice=load_row.add{type='drop-down',name='bfh_generation_load',items={{'bfh.load-minimal'},{'bfh.load-normal'},{'bfh.load-fast'}},selected_index=load_index}
  load_choice.style.width=300;load_choice.tooltip={'bfh.load-tooltip'}
  local notice_row=pages.generation.add{type='flow',direction='horizontal'}
  notice_row.add{type='label',caption={'bfh.notice-interval'}}.style.width=140
  local notice_items={};for _,seconds in ipairs(progress_notice.values) do notice_items[#notice_items+1]={'bfh.notice-seconds',seconds} end
  local notice_choice=notice_row.add{type='drop-down',name='bfh_notice_interval',items=notice_items,selected_index=progress_notice.index(s.notice_interval),tooltip={'bfh.notice-tooltip'}}
  notice_choice.style.width=300
  local search_row=pages.generation.add{type='flow',direction='horizontal'}
  search_row.add{type='label',caption={'bfh.layout-search-label'}}.style.width=140
  local search_choice=search_row.add{type='drop-down',name='bfh_layout_search',items={{'bfh.layout-search-normal'},{'bfh.layout-search-thorough'}},selected_index=s.layout_search=='thorough' and 2 or 1,tooltip={'bfh.layout-search-help'}}
  search_choice.style.width=300
  gui_layout.note(pages.generation,'layout-search-help')
  gui_layout.note(pages.connections,'connections-help')
  gui_layout.note(pages.connections,'output-help')
  local distribution_row=pages.connections.add{type='flow',direction='horizontal'}
  distribution_row.add{type='label',caption={'bfh.distribution-label'}}.style.width=140
  local distribution=distribution_row.add{type='drop-down',name='bfh_distribution',items={{'bfh.distribution-belts'},{'bfh.distribution-containers'}},selected_index=s.distribution_mode=='containers' and 2 or 1,tooltip={'bfh.distribution-tooltip'}}
  distribution.style.width=300
  local container_names={'auto'};local container_items={{'bfh.container-auto'}};local container_index=1
  local unlocked=equipment_catalog.items(player.force)
  for _,c in ipairs(container_distribution.catalog(player.force)) do
    local item
    for n,entity in pairs(unlocked) do if entity==c.name and (not item or n<item) then item=n end end
    container_names[#container_names+1]=c.name
    container_items[#container_items+1]={'','[item='..item..'] ',prototypes.item[item].localised_name,' - ',c.w,'x',c.h,'; ',{'bfh.container-slots',c.slots}}
    if s.container_name==c.name then container_index=#container_names end
  end
  local container_row=pages.connections.add{type='flow',direction='horizontal'}
  container_row.add{type='label',caption={'bfh.container-label'}}.style.width=140
  local container=container_row.add{type='drop-down',name='bfh_container',items=container_items,selected_index=container_index,tags={names=container_names},enabled=#container_names>1}
  container.style.width=300
  gui_layout.note(pages.connections,'container-help')

  local shape_row=pages.connections.add{type='flow',direction='horizontal'}
  shape_row.add{type='label',caption={'bfh.shape-label'}}.style.width=140
  local shapes={'auto','square','horizontal','vertical'};local shape_index=1
  for i,value in ipairs(shapes) do if value==s.layout_shape then shape_index=i end end
  shape_row.add{type='drop-down',name='bfh_layout_shape',items={{'bfh.shape-auto'},{'bfh.shape-square'},{'bfh.shape-horizontal'},{'bfh.shape-vertical'}},selected_index=shape_index,tooltip={'bfh.shape-help'}}.style.width=300
  local shape_help=pages.connections.add{type='label',name='bfh_shape_help',caption={'bfh.shape-help'}};shape_help.style.single_line=false;shape_help.style.maximal_width=510
  local independent_help=pages.connections.add{type='label',name='bfh_independent_layout_help',caption={'bfh.independent-layout-help'}};independent_help.style.single_line=false;independent_help.style.maximal_width=510

  for _,kind in ipairs({'input','output'}) do
    local row=pages.connections.add{type='flow',direction='horizontal'};row.style.vertical_align='center'
    row.add{type='label',caption={'bfh.'..kind..'-side'}}.style.width=140
    for _,option in ipairs({{0,'↑'},{4,'→'},{8,'↓'},{12,'←'}}) do
      local button=row.add{type='button',name='bfh_'..kind..'_side_'..option[1],caption=side_preview.arrow(kind,option[1]),auto_toggle=true,tags={action='bfh_side',kind=kind,side=option[1]},tooltip={'bfh.'..kind..'-side-'..option[1]}}
      button.style.width=44;button.style.height=32
    end
  end
  side_preview.create(pages.connections)
  update_side_controls(frame,s)
  local PIPE_ITEMS = get_pipe_items(player.force)
  add_dropdown_row(pages.connections, {"bfh.pipe"}, "bfh_pipe", PIPE_ITEMS, idx_of(PIPE_ITEMS, s.pipe))
  local fluid_catalog=fmf.catalog(player.force,s.pipe or 'pipe',equipment.items)
  local fluid_items={{'bfh.fluid-ordinary'}};local fluid_names={'ordinary'}
  if fluid_catalog.available then fluid_items[#fluid_items+1]={'bfh.fluid-fmf'};fluid_names[#fluid_names+1]='fmf' end
  local fluid_row=pages.connections.add{type='flow',direction='horizontal'}
  fluid_row.add{type='label',caption={'bfh.fluid-mode'}}.style.width=140
  local fluid_choice=fluid_row.add{type='drop-down',name='bfh_fluid_mode',items=fluid_items,selected_index=s.fluid_mode=='fmf' and #fluid_names or 1,tags={names=fluid_names},tooltip={'bfh.fmf-help'}}
  fluid_choice.style.width=300
  local fluid_help=pages.connections.add{type='label',name='bfh_fmf_help',caption={'bfh.'..(fluid_catalog.available and 'fmf-help' or 'fmf-unavailable')}}
  fluid_help.style.single_line=false;fluid_help.style.maximal_width=510

  local plates_available=display_plates.available()
  pages.connections.add{type='checkbox',name='bfh_use_display_plates',caption={'bfh.use-display-plates'},
    state=plates_available and s.use_display_plates==true,enabled=plates_available,
    tooltip=plates_available and {'bfh.display-plates-tooltip'} or {'bfh.display-plates-unavailable'}}

  -- Связь блоков: label + два radiobutton'а в КОЛОНКУ (горизонтально не помещается в узкий фрейм).
  local lr = pages.connections.add{ type="flow", direction="vertical" }
  lr.style.top_margin = 6
  lr.add{ type="label", caption={"bfh.link-mode"}, style="bold_label" }
  lr.add{ type="radiobutton", name="bfh_link_auto",
    caption={"bfh.link-auto"}, state=false, enabled=false,
    tooltip={"bfh.bus-disabled"} }
  lr.add{ type="radiobutton", name="bfh_link_direct",
    caption={"bfh.link-direct"}, state=(s.link_mode~="independent"),
    tags={ action="bfh_link", mode="direct" } }
  lr.add{ type="radiobutton", name="bfh_link_independent",
    caption={"bfh.link-independent"}, state=(s.link_mode=="independent"),
    tags={ action="bfh_link", mode="independent" } }

  pages.connections.add{type='line'}
  pages.connections.add{type='checkbox',name='bfh_use_power',caption={'bfh.use-power'},state=s.use_power~=false}
  local pole_names={'auto'};local pole_items={{'bfh.pole-auto'}};local pole_index=1
  local available_poles=power_planner.catalog(player.force)
  for _,p in ipairs(available_poles) do
    pole_names[#pole_names+1]=p.name;pole_items[#pole_items+1]=equipment_caption.make(p.name)
    if p.name==s.pole_name then pole_index=#pole_names end
  end
  local pole_row=pages.connections.add{type='flow',direction='horizontal'}
  pole_row.add{type='label',caption={'bfh.pole-type'}}.style.width=140
  local pole_choice=pole_row.add{type='drop-down',name='bfh_pole',items=pole_items,selected_index=pole_index,tags={names=pole_names},enabled=s.use_power~=false and #available_poles>0}
  pole_choice.style.width=300
  gui_layout.note(pages.connections,'power-help')
  update_side_controls(frame,s)
  frame.add{ type="line" }
  local ft = frame.add{ type="flow", direction="horizontal" }
  ft.style.horizontal_align = "right"
  ft.style.horizontally_stretchable=true
  ft.add{ type="button", caption={"bfh.close"}, tags={ action="bfh_close" } }
end

local function save_settings_from_gui(player, s)
  local f = player.gui.screen[GUI_NAME]
  if not f or not f.valid then return end
  local bi  = get_dd(f, "bfh_belt_in")
  local bo  = get_dd(f, "bfh_belt_out")
  local ii  = get_dd(f, "bfh_inserter_in")
  local iou = get_dd(f, "bfh_inserter_out")
  local pp  = get_dd(f, "bfh_pipe")
  local reserve_choice=get_dd(f,'bfh_reserve')
  if reserve_choice then s.reserve_percent=({0,5,10,20})[reserve_choice.selected_index] or 0 end
  local load_choice=get_dd(f,'bfh_generation_load')
  if load_choice then s.generation_load=({'minimal','normal','fast'})[load_choice.selected_index] end
  local notice_choice=get_dd(f,'bfh_notice_interval')
  if notice_choice then
    s.notice_interval=progress_notice.seconds(progress_notice.values[notice_choice.selected_index])
    local job=storage.bfh_generation
    if job and job.player_index==player.index then job.settings.notice_interval=s.notice_interval end
  end
  local shape_choice=get_dd(f,'bfh_layout_shape');if shape_choice then s.layout_shape=({'auto','square','horizontal','vertical'})[shape_choice.selected_index] end
  local search_choice=get_dd(f,'bfh_layout_search');if search_choice then s.layout_search=search_choice.selected_index==2 and 'thorough' or 'normal' end
  local quality=get_dd(f,'bfh_transport_quality')
  if quality then s.transport_quality=quality.tags.names[quality.selected_index] or 'normal' end
  local policy=get_dd(f,'bfh_transfer_mode');local loader=get_dd(f,'bfh_loader')
  if policy then s.transfer_mode=transfer_modes[policy.selected_index] end
  if loader then s.loader_name=loader.tags.names[loader.selected_index] or 'auto' end
  local distribution=get_dd(f,'bfh_distribution');if distribution then s.distribution_mode=distribution.selected_index==2 and 'containers' or 'belts' end
  local container=get_dd(f,'bfh_container');if container then s.container_name=container.tags.names[container.selected_index] or 'auto' end
  local power=get_dd(f,'bfh_use_power');if power then s.use_power=power.state end
  local pole=get_dd(f,'bfh_pole');if pole then s.pole_name=pole.tags.names[pole.selected_index] or 'auto' end
  local plates=get_dd(f,'bfh_use_display_plates')
  if plates then s.use_display_plates=plates.state and display_plates.available() end
  if bi then s.belt_in=bi.tags.names[bi.selected_index] or s.belt_in end
  if bo then s.belt_out=bo.tags.names[bo.selected_index] or s.belt_out end
  if ii  then s.inserter_in  = ii.tags.names[ii.selected_index]  end
  if iou then s.inserter_out = iou.tags.names[iou.selected_index] end
  if pp then s.pipe=pp.tags.names[pp.selected_index] or s.pipe end
  local fluid_mode=get_dd(f,'bfh_fluid_mode');if fluid_mode then s.fluid_mode=fluid_mode.tags.names[fluid_mode.selected_index] or 'ordinary' end
end

local function update_fluid_controls(frame,player,settings)
  local choice=get_dd(frame,'bfh_fluid_mode');if not choice then return end
  local catalog=fmf.catalog(player.force,settings.pipe or 'pipe')
  local names={'ordinary'};local items={{'bfh.fluid-ordinary'}}
  if catalog.available then names[#names+1]='fmf';items[#items+1]={'bfh.fluid-fmf'} else settings.fluid_mode='ordinary' end
  choice.items=items;choice.tags={names=names};choice.selected_index=settings.fluid_mode=='fmf' and 2 or 1
  local help=get_dd(frame,'bfh_fmf_help');if help then help.caption={'bfh.'..(catalog.available and 'fmf-help' or 'fmf-unavailable')} end
end

local function update_link_radios(frame,mode)
  for name,state in pairs({bfh_link_auto=false,bfh_link_direct=mode~='independent',bfh_link_independent=mode=='independent'}) do
    local element=get_dd(frame,name);if element then element.state=state end
  end
end

local function open_or_close(p)
  if p.gui.screen[GUI_NAME] then save_settings_from_gui(p,get_settings(p.index));destroy_gui(p) else build_gui(p) end
end

script.on_init(function() storage.bfh_settings = storage.bfh_settings or {} end)
script.on_configuration_changed(function(event)
  storage.bfh_settings=storage.bfh_settings or {}
  local job=storage.bfh_generation
  if job and event.mod_changes and event.mod_changes['blueprint-from-helmod'] then
    -- Older snapshots did not retain modules/beacons. Never silently finish
    -- an upgraded job from an incomplete equipment snapshot.
    local player=game.get_player(job.player_index);discard_generation()
    if player then player.print({'bfh.generation-update-restart'}) end
  elseif job and not job.inventory and (next(event.mod_changes or {}) or event.mod_startup_settings_changed or event.migration_applied) then
    local player=game.get_player(job.player_index)
    if player then player.print({'bfh.generation-environment-restart'}) end
    job.completed=nil;job.cache={};job.started_tick=game.tick;job.last_notice=game.tick
  end
end)

script.on_event("bfh-open-gui-hotkey", function(ev)
  local p = game.get_player(ev.player_index)
  if p then open_or_close(p) end
end)

script.on_event(defines.events.on_lua_shortcut, function(ev)
  if ev.prototype_name ~= "bfh-open-gui" then return end
  local p = game.get_player(ev.player_index)
  if p then open_or_close(p) end
end)

script.on_event(defines.events.on_gui_click, function(ev)
  local p = game.get_player(ev.player_index)
  if not p then return end
  local el = ev.element
  if not el or not el.valid then return end
  local t = el.tags
  if not t or not t.action then return end

  if t.action == "bfh_close" then
    save_settings_from_gui(p,get_settings(p.index))
    destroy_gui(p)
  elseif t.action == 'bfh_blacklist_remove' then
    local s=get_settings(p.index);s.entity_blacklist=s.entity_blacklist or {};s.entity_blacklist[t.entity]=nil
    local frame=p.gui.screen[GUI_NAME];local page=frame and get_dd(frame,'bfh_page_exclusions')
    if page then entity_blacklist.draw(page,s);entity_blacklist.warning(page,s) end
  elseif t.action == "bfh_link" then
    local s = get_settings(p.index)
    s.link_mode = t.mode=="independent" and "independent" or "direct"
    local f = p.gui.screen[GUI_NAME]
    if f and f.valid then update_link_radios(f, t.mode);update_side_controls(f,s) end
  elseif t.action == 'bfh_side' then
    if (t.kind=='input' or t.kind=='output') and ({[0]=true,[4]=true,[8]=true,[12]=true})[t.side] then
      local s=get_settings(p.index);s[t.kind..'_side']=t.side
      local frame=p.gui.screen[GUI_NAME];if frame then update_side_controls(frame,s) end
    end
  elseif t.action == "bfh_generate" then
    local s = get_settings(p.index)
    save_settings_from_gui(p, s)
    s.force_name=p.force.name
    local ok, models = pcall(remote.call, "helmod_interface", "get_models")
    if not ok or not models then p.print({"bfh.helmod-error"}) return end
    local m = models[t.model_id]
    if not m then p.print({"bfh.model-not-found"}) return end
    if not model_owned_by(m,p) then p.print({'bfh.helmod-not-owned'}) return end
    -- t.block_id задан → строим только этот под-блок, иначе всю линию.
    local recipes = collect_recipes(m, nil, nil, t.block_id, nil)
    if #recipes == 0 then p.print({"bfh.no-recipes"}) return end
    local conflict=entity_blacklist.check(s,recipes)
    if conflict then p.print(conflict);return end
    destroy_gui(p)
    generate_blueprint(p, recipes, s)
  end
end)

script.on_event(defines.events.on_gui_closed, function(ev)
  if ev.element and ev.element.valid and ev.element.name == GUI_NAME then
    local p = game.get_player(ev.player_index)
    if p then save_settings_from_gui(p,get_settings(p.index));destroy_gui(p) end
  end
end)

script.on_event(defines.events.on_gui_checked_state_changed,function(ev)
  local el=ev.element
  if el and el.valid and el.name=='bfh_use_power' then
    get_settings(ev.player_index).use_power=el.state
    local player=game.get_player(ev.player_index);local frame=player and player.gui.screen[GUI_NAME];local choice=frame and get_dd(frame,'bfh_pole')
    if choice then choice.enabled=el.state and #choice.tags.names>1 end
  end
  if el and el.valid and el.name=='bfh_use_display_plates' then
    get_settings(ev.player_index).use_display_plates=el.state and display_plates.available()
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed,function(event)
 local element=event.element
 if not element or not element.valid then return end
 local player=game.get_player(event.player_index)
 local frame=player and player.gui.screen[GUI_NAME]
 if not frame or not frame.valid or get_dd(frame,element.name)~=element then return end
 local settings=get_settings(player.index);save_settings_from_gui(player,settings)
 local exclusions=get_dd(frame,'bfh_page_exclusions');if exclusions then entity_blacklist.warning(exclusions,settings) end
 if element.name=='bfh_layout_shape' or element.name=='bfh_distribution' then update_side_controls(frame,settings) end
  if element.name=='bfh_pipe' then update_fluid_controls(frame,player,settings) end
 if element.name=='bfh_transfer_mode' then
  update_equipment_controls(frame,settings.transfer_mode)
 end
end)

script.on_event(defines.events.on_gui_elem_changed,function(event)
 local el=event.element;local player=game.get_player(event.player_index)
 local frame=player and player.gui.screen[GUI_NAME]
 if not el or not el.valid or not frame or get_dd(frame,'bfh_blacklist_pick')~=el then return end
 local name=el.elem_value;if not name or not prototypes.entity[name] then return end
 local s=get_settings(player.index);save_settings_from_gui(player,s)
 s.entity_blacklist=s.entity_blacklist or {};s.entity_blacklist[name]=true;el.elem_value=nil
 local page=get_dd(frame,'bfh_page_exclusions');entity_blacklist.draw(page,s);entity_blacklist.warning(page,s)
end)
