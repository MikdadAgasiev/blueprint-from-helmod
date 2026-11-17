local M={}
local capacity=require('capacity')
local orientation=require('orientation')
local containers=require('container_distribution')
local export_layout=require('export_layout')
local resources=require('resources')
-- Calculate requested exports before adding spare intermediate production.
function M.balance(recipes,imports)
 local balances={}
 for _,r in ipairs(recipes) do
  for _,side in ipairs({'products','ingredients'}) do
   for _,v in ipairs(r[side] or {}) do
    local key=(v.type or 'item')..'/'..v.name
    local b=balances[key]
    if not b then b={name=v.name,type=v.type or 'item',rate=0};balances[key]=b end
    local rate=capacity.flow(v,r)
    if b.type=='fluid' and side=='ingredients' then b.internal_rate=(b.internal_rate or 0)+rate end
    b.rate=b.rate+(side=='products' and 1 or -1)*rate
   end
  end
 end
 local result={}
 for _,b in pairs(balances) do
  if imports then b.rate=-b.rate end
  if b.rate>1e-8 then result[#result+1]=b end
 end
 table.sort(result,function(a,b)return a.type..'/'..a.name<b.type..'/'..b.name end)
 return result
end
-- Export ports participate in the same flow allocation as machine inputs.
-- In particular, a product may be consumed internally AND exported.
function M.plan(entities,requirements,settings,en,blocks)
 local side=orientation.output(settings);local turns=((side-4)/4)%4
 local right,top,bottom=-math.huge,math.huge,-math.huge
 for _,e in ipairs(entities) do
  local pos=orientation.point(e.position,-turns,false)
  local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
  if ((e.direction or 0)-turns*4)%8==4 then w,h=h,w end
  right=math.max(right,math.ceil(pos.x+w/2-.001))
  top=math.min(top,math.floor(pos.y-h/2+.001));bottom=math.max(bottom,math.ceil(pos.y+h/2-.001))
 end
 if right==-math.huge then return {},{},en end
 local count=0;local speed=capacity.belt(settings.belt_out)
 for _,b in ipairs(requirements) do if b.type=='item' then count=count+math.max(1,math.ceil(b.rate/speed-1e-9)) end end
 local context,container_settings
 if count>0 and settings.distribution_mode=='containers' then
  container_settings={};for k,v in pairs(settings) do container_settings[k]=v end
  container_settings.belt_in=settings.belt_out
  context=containers.context(container_settings);context.output_collector=true
 end
 local banks,total_height,max_width={},0,0
 for _,b in ipairs(requirements) do if b.type=='item' then
  local n=math.max(1,math.ceil(b.rate/(context and context.capacity or speed)-1e-9))
  local box=context and containers.select(context,n,n)
  if context and not box then error({'bfh.container-no-size',n,n},0) end
  local height=box and box.h+6 or n*3
  banks[#banks+1]={resource=b,name=b.name,n=n,height=height,anchor=box and 3 or 0,tail_space=box and 0 or 2};total_height=total_height+height
  max_width=math.max(max_width,box and box.w or 0)
 end end
 local y=math.floor((top+bottom-total_height+3)/2)
 -- Use the actual source rows, including multiple sources and output banks.
 local samples={}
 for _,block in ipairs(blocks or {}) do
  for _,product in ipairs((block.recipe_node or {}).products or {}) do
   if product.type~='fluid' and block.product_out then
    local rate=capacity.flow(product,block.recipe_node)
    local ports=resources.ports(block,product.name)
    samples[product.name]=samples[product.name] or {}
    for _,port in ipairs(ports) do
     samples[product.name][#samples[product.name]+1]={y=orientation.point(port,-turns,true).y,weight=rate/#ports}
    end
   end
  end
 end
 y=export_layout.place(banks,samples,top,bottom,y)
 local outputs,consumers={},{}
 local function consumer(port,inlet)
  consumers[#consumers+1]={is_external_output=true,export=port,products={},inputs={{x=inlet.x,y=inlet.y,direction=inlet.direction,ingredient=port.name}},
   recipe_node={base_time=1,ingredients={{name=port.name,type='item',count=port.rate}},products={}},offset_y=inlet.y,height=1}
 end
 for _,bank in ipairs(banks) do local b,n=bank.resource,bank.n
  if context then
   local initial=#entities
   local inputs,exits,height,next_en=containers.emit(entities,en,context,container_settings,n,n,right+max_width+8,y,b.name)
   en=next_en
   for i=initial+1,#entities do orientation.entity(entities[i],turns) end
   local sources={};local flow={required=b.rate,allocated=0}
   for i,p in ipairs(exits) do
    p.export_slot=i;p.name=b.name;p.type='item';p.rate=b.rate/n;p.sources=sources;p.flow=flow;orientation.port(p,turns)
    outputs[#outputs+1]=p;orientation.port(inputs[i],turns);consumer(p,inputs[i])
   end
  else
  for i=1,n do
   local port={export_slot=i,x=right+math.max(4,count+2),y=y,direction=4,name=b.name,type='item',rate=b.rate/n,sources={},flow={required=b.rate/n,allocated=0}}
   orientation.port(port,turns)
   entities[#entities+1]={entity_number=en,name=settings.belt_out,position={x=port.x+.5,y=port.y+.5},direction=port.direction};en=en+1
   outputs[#outputs+1]=port
   consumer(port,port)
   y=y+3
  end
  end
  if context then y=y+bank.height end
 end
 return outputs,consumers,en
end
function M.issues(blocks,outputs)
 local issues={};local seen={}
 local function check(name,need,got)
  if need and (got or 0)+1e-7<need then
   issues[#issues+1]=string.format('Insufficient belt allocation: %s required %.9g connected %.9g',name,need,got or 0)
  end
 end
 for _,b in ipairs(blocks or {}) do for _,p in ipairs(b.inputs or {}) do check(p.ingredient,p.planned_rate,p.connected_rate) end end
 for _,p in ipairs(outputs or {}) do if p.flow and not seen[p.flow] then
  seen[p.flow]=true;check(p.name,p.flow.required,p.flow.allocated)
 end end
 return issues
end
return M
