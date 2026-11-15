local M={}
local orientation=require('orientation')
local capacity=require('capacity')
local fmf=require('fmf')
local export_layout=require('export_layout')
local directions={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}

function M.plan_fluids(entities,requirements,ports,settings)
 local side=orientation.output(settings)
 local turns=((side-4)/4)%4
 local right,top,bottom=-math.huge,math.huge,-math.huge
 for _,entity in ipairs(entities) do
  local position=orientation.point(entity.position,-turns,false)
  local prototype=prototypes.entity[entity.name]
  local width,height=prototype.tile_width,prototype.tile_height
  if ((entity.direction or 0)-turns*4)%8==4 then width,height=height,width end
  right=math.max(right,math.ceil(position.x+width/2-.001))
  top=math.min(top,math.floor(position.y-height/2+.001))
  bottom=math.max(bottom,math.ceil(position.y+height/2-.001))
 end
 local outputs={}
 if right==-math.huge then return outputs end
 local count=0
 for _,flow in ipairs(requirements) do if flow.type=='fluid' then count=count+1 end end
 local y=side==12 and top-count*4-4 or math.floor((top+bottom-count*4+3)/2)
 local banks,samples={},{}
 for _,flow in ipairs(requirements) do if flow.type=='fluid' then
  banks[#banks+1]={name=flow.name,resource=flow,height=4,tail_space=3}
 end end
 for _,port in ipairs(ports) do if port.kind=='output' and not port.terminal then
  samples[port.fluid]=samples[port.fluid] or {}
  samples[port.fluid][#samples[port.fluid]+1]={y=orientation.point(port,-turns,true).y,weight=port.rate or 1}
 end end
 -- Left-side exports retain their separate corridor above the external inputs.
 local aligned=export_layout.place(banks,samples,top,bottom,y)
 if side~=12 then y=aligned end
 for _,bank in ipairs(banks) do
   local flow=bank.resource
   local output={x=right+4,y=y,direction=4,name=flow.name,type='fluid',rate=flow.rate,sources={},internal_rate=flow.internal_rate}
   orientation.port(output,turns)
   outputs[#outputs+1]=output
   ports[#ports+1]={x=output.x,y=output.y,dir=output.direction,fluid=flow.name,kind='input',block=0,external=true,terminal=true,rate=flow.rate}
   y=y+4
 end
 return outputs
end

-- Wire the export pump to the upstream pipe so an empty outside network
-- cannot drain the supply reserved for the machines.
function M.prioritize_fluids(entities,outputs,blocks,unlocked,fmf_catalog)
 local pump=prototypes.entity.pump
 local pipe=prototypes.entity.pipe
 local modes=defines.control_behavior.single_fluid_box
 if not modes or not pump or pump.tile_width~=1 or pump.tile_height~=2 or not pipe then return end
 local needs_priority=false
 for _,output in ipairs(outputs) do if (output.internal_rate or 0)>0 then needs_priority=true;break end end
 if not needs_priority then return end
 if unlocked.pump~='pump' and not (fmf_catalog and fmf_catalog.priority) then return end
 local installed_demand={}
 for _,block in ipairs(blocks) do
  local recipe=block.recipe_node
  for _,flow in ipairs(recipe and recipe.ingredients or {}) do
   if flow.type=='fluid' then
    local rate=capacity.flow(flow,recipe)*math.max(1,recipe.physical_capacity_factor or 1)
    installed_demand[flow.name]=(installed_demand[flow.name] or 0)+rate
   end
  end
 end
 local occupied,by_cell,next_id={},{},1
 for _,entity in ipairs(entities) do
  local proto=prototypes.entity[entity.name]
  local w,h=proto.tile_width,proto.tile_height
  if (entity.direction or 0)%8==4 then w,h=h,w end
  local x,y=math.floor(entity.position.x-w/2+.001),math.floor(entity.position.y-h/2+.001)
  for xx=x,x+w-1 do for yy=y,y+h-1 do occupied[xx..','..yy]=true end end
  if entity.name=='pipe' then by_cell[x..','..y]=entity end
  next_id=math.max(next_id,entity.entity_number+1)
 end
 for _,output in ipairs(outputs) do
  local planned_demand=output.internal_rate or 0
  -- Whole-machine rounding can let internal consumers take the entire supply.
  -- Preserve the passive outlet when prioritizing would remove that export.
  local has_surplus=planned_demand+output.rate>(installed_demand[output.name] or 0)+1e-8
  local sensor=planned_demand>0 and has_surplus and by_cell[output.x..','..output.y]
  if sensor then
   local dx,dy=table.unpack(directions[output.direction])
   local x,y=output.x,output.y
   local gate,valve,length=fmf.export_gate(output,next_id,fmf_catalog)
   if not gate and unlocked.pump=='pump' and output.rate<=(pump.get_pumping_speed('normal') or 0)*60 then
    valve={entity_number=next_id,name='pump',position={x=x+.5+1.5*dx,y=y+.5+1.5*dy},direction=output.direction}
    gate={valve};length=2
   end
   local cells={};local clear=gate~=nil
   for _,entity in ipairs(gate or {}) do
    local proto=prototypes.entity[entity.name];local w,h=proto.tile_width,proto.tile_height
    if (entity.direction or 0)%8==4 then w,h=h,w end
    local left,top=math.floor(entity.position.x-w/2+.001),math.floor(entity.position.y-h/2+.001)
    for xx=left,left+w-1 do for yy=top,top+h-1 do
     local cell=xx..','..yy
     if occupied[cell] or cells[cell] then clear=false end
     cells[cell]=true
    end end
   end
   if clear and fmf_catalog then clear=fmf.export_clear(gate,occupied,output) end
   if clear and not occupied[(x+(length+1)*dx)..','..(y+(length+1)*dy)] then
    local red=defines.wire_connector_id.circuit_red
    sensor.control_behavior={circuit_mode_of_operation=modes.exclusive_mode.send_contents}
    sensor.wires=sensor.wires or {}
    sensor.wires[#sensor.wires+1]={sensor.entity_number,red,valve.entity_number,red}
    valve.control_behavior={circuit_enabled=true,circuit_condition={
     first_signal={type='fluid',name=output.name},comparator='>',constant=math.max(1,math.floor(pipe.fluid_capacity*0.1)),
    }}
    for _,entity in ipairs(gate) do
     if entity.name=='duct-intake' then
      entity.control_behavior={circuit_enabled=true,circuit_condition=valve.control_behavior.circuit_condition}
      sensor.wires[#sensor.wires+1]={sensor.entity_number,red,entity.entity_number,red}
     end
     entities[#entities+1]=entity
    end
    for cell in pairs(cells) do occupied[cell]=true end
    output.x,output.y=x+length*dx,y+length*dy
    output.priority=true
    output.priority_device=valve.name
    next_id=next_id+#gate
   end
  end
 end
end

function M.demands(outputs)
 local result={};local groups={}
 for _,p in ipairs(outputs or {}) do if p.type=='item' then
  if not groups[p.name] then groups[p.name]={sources={},targets={},seen={}} end
  local g=groups[p.name]
  for _,source in ipairs(p.sources or {}) do
   local key=source.x..','..source.y
   if not g.seen[key] then g.sources[#g.sources+1]=source;g.seen[key]=true end
  end
  groups[p.name].targets[#groups[p.name].targets+1]={x=p.x,y=p.y}
 end end
 for name,g in pairs(groups) do
  for _,target in ipairs(g.targets) do
   result[#result+1]={x=target.x,y=target.y,name=name,sources=g.sources}
  end
  for _,source in ipairs(g.sources) do
   result[#result+1]={x=g.targets[1].x,y=g.targets[1].y,name=name,sources={source},targets=g.targets}
  end
 end
 return result
end
return M
