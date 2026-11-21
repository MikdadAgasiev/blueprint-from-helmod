-- Per-player exclusions are passed with the generation settings, never global.
local M={}
local helmod=require('helmod_equipment')
local pipe_pair=require('pipe_pair')
local function caption(name)
 local p=prototypes.entity[name or ''];return p and p.localised_name or name or '?'
end
function M.check(settings,recipes)
 local blocked=settings.entity_blacklist or {}
 if next(blocked)==nil then return end
 local function selected(name,label)
  if name and blocked[name] then return {'bfh.blacklist-conflict',label,caption(name)} end
 end
 local fields={}
 if settings.transfer_mode~='auto_equipment' then
  fields={{'belt_in','belt-in'},{'belt_out','belt-out'}}
  if settings.transfer_mode~='auto' then
   fields[#fields+1]={'inserter_in','inserter-in'};fields[#fields+1]={'inserter_out','inserter-out'}
  end
  if settings.transfer_mode=='loaders' or settings.transfer_mode=='auto' or settings.distribution_mode=='containers' then fields[#fields+1]={'loader_name','transfer-loader'} end
 end
 fields[#fields+1]={'pipe','pipe'}
 if settings.use_power~=false then fields[#fields+1]={'pole_name','pole-type'} end
 if settings.distribution_mode=='containers' then fields[#fields+1]={'container_name','container-label'} end
 for _,field in ipairs(fields) do
  local name=settings[field[1]];local error=selected(name,{'bfh.'..field[2]});if error then return error end
  local p=name and prototypes.entity[name]
  if p and p.type=='transport-belt' then
   local q=p.related_underground_belt
   if q and blocked[q.name] then return {'bfh.blacklist-dependency',caption(name),caption(q.name)} end
   local splitter=name:gsub('transport%-belt','splitter')
   if splitter~=name and blocked[splitter] then return {'bfh.blacklist-dependency',caption(name),caption(splitter)} end
  elseif p and p.type=='pipe' then
   local ug=pipe_pair.resolve(name)
   if ug and blocked[ug] then return {'bfh.blacklist-dependency',caption(name),caption(ug)} end
  end
 end
 for _,recipe in ipairs(recipes or {}) do
  local name=recipe.factory and recipe.factory.name
  if blocked[name] then return {'bfh.blacklist-plan',caption(name)} end
  for _,b in ipairs(helmod.beacons(recipe)) do if blocked[b.name] then return {'bfh.blacklist-plan',caption(b.name)} end end
 end
end
function M.validate_entities(entities,settings)
 local blocked=settings.entity_blacklist or {}
 if next(blocked)==nil then return end
 for _,e in ipairs(entities) do
  if blocked[e.name] then error({'bfh.blacklist-generated',caption(e.name)},0) end
 end
end
function M.draw(parent,settings)
 local list=parent.bfh_blacklist_list;list.clear()
 local names={};for name,value in pairs(settings.entity_blacklist or {}) do if value then names[#names+1]=name end end;table.sort(names)
 for _,name in ipairs(names) do
  local row=list.add{type='flow',direction='horizontal'};row.style.vertical_align='center'
  if prototypes.entity[name] then row.add{type='sprite',sprite='entity/'..name} end
  local label=row.add{type='label',caption=caption(name),tooltip=name};label.style.width=350
  row.add{type='button',caption='×',tooltip={'bfh.blacklist-remove'},tags={action='bfh_blacklist_remove',entity=name}}
 end
 if #names==0 then list.add{type='label',caption={'bfh.blacklist-empty'}} end
end
function M.warning(parent,settings)
 parent.bfh_blacklist_warning.caption=M.check(settings) or ''
end
function M.build(parent,settings)
 local help=parent.add{type='label',caption={'bfh.blacklist-help'}};help.style.single_line=false;help.style.maximal_width=510
 local row=parent.add{type='flow',direction='horizontal'};row.style.vertical_align='center'
 row.add{type='label',caption={'bfh.blacklist-add'}}
 row.add{type='choose-elem-button',name='bfh_blacklist_pick',elem_type='entity',tooltip={'bfh.blacklist-add'}}
 parent.add{type='flow',name='bfh_blacklist_list',direction='vertical'}
 local warning=parent.add{type='label',name='bfh_blacklist_warning',caption=''}
 warning.style.single_line=false;warning.style.maximal_width=510;warning.style.font_color={1,.6,.3}
 M.draw(parent,settings);M.warning(parent,settings)
end
return M
