-- Equipment belongs to the selected Helmod recipe, including item qualities.
local M={}
local work=require('generation_work')
local function quality(value)
  if type(value)=='table' then return value.name or 'normal' end
  return value or 'normal'
end
function M.modules(values)
  local totals={}
  for _,v in pairs(values or {}) do
    local amount=tonumber(v.amount or v.count) or 0
    if amount<0 or amount%1~=0 then error({'bfh.plan-equipment-invalid','module count'},0) end
    if amount>0 then
      local q=quality(v.quality);local key=v.name..'/'..q
      totals[key]=totals[key] or {name=v.name,quality=q,amount=0}
      totals[key].amount=totals[key].amount+amount
    end
  end
  local keys={};for key in pairs(totals) do keys[#keys+1]=key end;table.sort(keys)
  local result={};for _,key in ipairs(keys) do result[#result+1]=totals[key] end
  return result
end
function M.factory(value)
  value=value or {}
  local result={name=value.name,count=value.count,quality=quality(value.quality),modules=M.modules(value.modules)}
  if value.effects then result.effects={};for _,key in ipairs({'speed','productivity','consumption','pollution','quality'}) do result.effects[key]=value.effects[key] end end
  return result
end
function M.beacons(recipe)
  local result={}
  local factory=prototypes and prototypes.entity and prototypes.entity[(recipe.factory or {}).name or '']
  if factory and factory.effect_receiver and factory.effect_receiver.uses_beacon_effects==false then return result end
  for _,v in ipairs(recipe.beacons or (recipe.beacon and {recipe.beacon}) or {}) do
    local n=tonumber(v.combo) or 0
    if n<0 or n%1~=0 then error({'bfh.plan-equipment-invalid','beacon count'},0) end
    if n>0 then
      local b=M.factory(v);b.combo=n;b.count=v.count;b.amount=v.amount
      b.per_factory=v.per_factory;b.per_factory_constant=v.per_factory_constant
      -- Helmod can retain a default beacon/combo with no installed modules.
      -- It has no useful effect and must not reserve a production cell.
      if #b.modules>0 then result[#result+1]=b end
    end
  end
  return result
end
function M.plan_beacons(recipes,place_items)
  local researched={}
  for _,name in pairs(place_items or {}) do researched[name]=true end
  local result=work.copy(recipes)
  for _,recipe in ipairs(result) do
    local beacons=M.beacons(recipe)
    for _,b in ipairs(beacons) do
      local beacon=prototypes.entity[b.name or '']
      if not beacon or beacon.type~='beacon' then error({'bfh.plan-equipment-invalid',b.name or 'beacon'},0) end
      if not researched[b.name] then
        local rp=prototypes.recipe[recipe.name]
        -- Removing a real configured effect would invalidate Helmod's rates
        -- and possibly its quality outputs. Ask for a corrected plan instead.
        error({'bfh.beacon-not-researched-plan',beacon and beacon.localised_name or b.name,rp and rp.localised_name or recipe.name},0)
      end
    end
    recipe.beacon=nil;recipe.beacons=beacons
  end
  return result
end
function M.validate_recipe(recipe)
  local q=quality(recipe.quality)
  if prototypes.quality and not prototypes.quality[q] then error({'bfh.plan-equipment-invalid',q},0) end
end
local function allowed(module,prototype,recipe,module_quality)
  for _,p in ipairs({prototype,recipe}) do
    if p then
      if p.allowed_module_categories and not p.allowed_module_categories[module.category] then return false end
      local effects=module.get_module_effects and module.get_module_effects(module_quality) or module.module_effects or {}
      for key,amount in pairs(effects) do
        if type(amount)=='table' then amount=amount.bonus or 0 end
        if amount>0 and p.allowed_effects and not p.allowed_effects[key] then return false end
      end
    end
  end
  return true
end
function M.apply(entity,factory,recipe_name)
  local p=prototypes.entity[entity.name];local q=quality(factory.quality)
  if prototypes.quality and not prototypes.quality[q] then error({'bfh.plan-equipment-invalid',q},0) end
  if q~='normal' then entity.quality=q end
  local modules=M.modules(factory.modules)
  if #modules==0 then return end
  local inventories={beacon=defines.inventory.beacon_modules,lab=defines.inventory.lab_modules,['mining-drill']=defines.inventory.mining_drill_modules,['agricultural-tower']=defines.inventory.agricultural_tower_modules}
  local inventory=inventories[p.type] or defines.inventory.crafter_modules
  local slots=p.get_inventory_size(inventory,q) or 0
  local index=0;entity.items={}
  for _,v in ipairs(modules) do
    local item=prototypes.item[v.name]
    if not item or item.type~='module' or (prototypes.quality and not prototypes.quality[v.quality]) or not allowed(item,p,recipe_name and prototypes.recipe[recipe_name],v.quality) then
      error({'bfh.plan-equipment-invalid',v.name..' / '..entity.name..' / '..(recipe_name or '')},0)
    end
    if index+v.amount>slots then error({'bfh.plan-equipment-invalid',entity.name..' / '..slots..' slots'},0) end
    local positions={}
    for i=1,v.amount do positions[#positions+1]={inventory=inventory,stack=index,count=1};index=index+1 end
    entity.items[#entity.items+1]={id={name=v.name,quality=v.quality},items={in_inventory=positions}}
  end
end
return M
