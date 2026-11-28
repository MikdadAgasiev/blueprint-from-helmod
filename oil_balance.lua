-- Balance optional oil cracking against the selected solid-product target.
local M={}
local work=require('generation_work')
local capacity=require('capacity')
local equipment=require('equipment')
local H,L,G='heavy-oil','light-oil','petroleum-gas'
local function flow(r,side,name)
 local total=0;for _,v in ipairs(r[side]or{})do if v.type=='fluid'and v.name==name then total=total+capacity.flow(v,r)end end;return total
end
local function scale(r,factor)
 local copy=work.copy(r);copy.count=(r.count or 0)*factor;copy.factory.count=r.factory.count*factor
 for _,side in ipairs({'ingredients','products'})do for i,v in ipairs(copy[side]or{})do v.count=capacity.flow(r[side][i],r)*(r.base_time or 1)*factor end end
 return copy
end
function M.solve(h,l,g,dh,dl,dg,hy,gy)
 if h<=0 or l<=0 or g<=0 or dg<=0 or hy<=0 or gy<=0 then return end
 local function at(s)
  local hs=h*s-dh;local ls=l*s+math.max(0,hs)*hy-dl
  return hs,ls,g*s+math.max(0,ls)*gy-dg
 end
 local a,b,c=at(1);if a< -1e-7 or b< -1e-7 or c< -1e-7 then return end
 local lo,hi=0,1
 for _=1,60 do local mid=(lo+hi)/2;local x,y,z=at(mid);if x>=0 and y>=0 and z>=0 then hi=mid else lo=mid end end
 local x,y,z=at(hi)
 -- If another requested fraction forces a gas surplus, keep the explicit plan.
 if z>1e-6 then return end
 return hi,math.max(0,x),math.max(0,y)
end
local function cracking(name,input,output,force,recipes,items)
 local rp=prototypes.recipe[name];local unlocked=force and force.recipes[name]
 if not rp or not unlocked or not unlocked.enabled or unlocked.hidden then return end
 local existing;for _,r in ipairs(recipes)do if r.name==name then if existing then return end;existing=r end end
 if existing then
  local consumed=flow(existing,'ingredients',input);local produced=flow(existing,'products',output)
  if consumed>0 and produced>0 then return existing,consumed,produced end
  return
 end
 local inside,outside=0,0
 for _,v in ipairs(rp.ingredients)do if v.type~='fluid'or(v.name~=input and v.name~='water')then return end;if v.name==input then inside=inside+v.amount end end
 for _,v in ipairs(rp.products)do if v.type~='fluid'or v.name~=output or v.probability and v.probability~=1 then return end;outside=outside+(v.amount or 0)end
 if inside<=0 or outside<=0 then return end
 local available={};for _,n in pairs(items)do available[n]=true end
 local names={};local seen={}
 for _,r in ipairs(recipes)do local n=(r.factory or{}).name;local p=prototypes.entity[n or'']
  local compatible=false;if p then for _,category in ipairs(rp.categories)do if(p.crafting_categories or{})[category]then compatible=true;break end end end
  if p and available[n]and p.type=='assembling-machine'and compatible and not seen[n]then names[#names+1]=n;seen[n]=true end
 end
 if #names==0 then
  for n in pairs(available)do local p=prototypes.entity[n]
   if p and p.type=='assembling-machine'then for _,category in ipairs(rp.categories)do if(p.crafting_categories or{})[category]then names[#names+1]=n;break end end end
  end
 end
 table.sort(names,function(a,b)if a=='chemical-plant'then return b~='chemical-plant'elseif b=='chemical-plant'then return false end;return a<b end)
 if #names==0 then return end
 local name_factory=names[1];local speed=prototypes.entity[name_factory].get_crafting_speed('normal')
 if not speed or speed<=0 then return end
 local node={name=name,class='Recipe',base_time=1,count=1,quality='normal',factory={name=name_factory,count=rp.energy/speed,quality='normal',modules={},effects={speed=0,productivity=0,consumption=0,pollution=0,quality=0}},beacons={},ingredients={},products={}}
 for _,side in ipairs({'ingredients','products'})do for _,v in ipairs(rp[side])do node[side][#node[side]+1]={type=v.type,name=v.name,amount=v.amount,count=v.amount}end end
 return node,inside,outside
end
function M.apply(recipes,force,settings)
 if settings.link_mode=='independent'or #recipes==0 then return {recipes=recipes}end
 for _,v in ipairs(recipes[1].products or{})do if v.type=='fluid'and(v.name==H or v.name==L or v.name==G)then return {recipes=recipes}end end
 local oil
 for _,r in ipairs(recipes)do if flow(r,'products',H)>0 and flow(r,'products',L)>0 and flow(r,'products',G)>0 then if oil then return {recipes=recipes}end;oil=r end end
 if not oil or not oil.factory or not oil.factory.count or oil.factory.count<=0 then return {recipes=recipes}end
 if flow(oil,'ingredients',H)>0 or flow(oil,'ingredients',L)>0 or flow(oil,'ingredients',G)>0 then return {recipes=recipes}end
 for _,r in ipairs(recipes)do for _,side in ipairs({'ingredients','products'})do for _,v in ipairs(r[side]or{})do
  if v.type=='fluid'and(v.name==H or v.name==L or v.name==G)and not capacity.explicit_flow(v,r)then return {recipes=recipes}end
 end end end
 local items=equipment.items(force,settings.entity_blacklist)
 local hc,hin,hout=cracking('heavy-oil-cracking',H,L,force,recipes,items)
 local lc,lin,lout=cracking('light-oil-cracking',L,G,force,recipes,items)
 if not hc or not lc then return {recipes=recipes}end
 local demand={[H]=0,[L]=0,[G]=0}
 for _,r in ipairs(recipes)do if r~=oil and r.name~=hc.name and r.name~=lc.name then for name in pairs(demand)do demand[name]=demand[name]+flow(r,'ingredients',name)-flow(r,'products',name)end end end
 for name,value in pairs(demand)do demand[name]=math.max(0,value)end
 local factor,heavy,light=M.solve(flow(oil,'products',H),flow(oil,'products',L),flow(oil,'products',G),demand[H],demand[L],demand[G],hout/hin,lout/lin)
 if not factor or heavy<1e-8 and light<1e-8 then return {recipes=recipes}end
 local result={};for _,r in ipairs(recipes)do if r==oil then result[#result+1]=scale(r,factor)elseif r.name~=hc.name and r.name~=lc.name then result[#result+1]=work.copy(r)end end
 local names={}
 if heavy>1e-8 then result[#result+1]=scale(hc,heavy/hin);names[hc.name]=H end
 if light>1e-8 then result[#result+1]=scale(lc,light/lin);names[lc.name]=L end
 -- Rebalance an existing water-only source as part of the adjusted oil chain.
 local water=0;local source
 for _,r in ipairs(result)do water=water+flow(r,'ingredients','water')-flow(r,'products','water');if #(r.ingredients or{})==0 and #(r.products or{})==1 and flow(r,'products','water')>0 then source=r end end
 if math.abs(water)>1e-7 and source then local old=flow(source,'products','water');if old+water>1e-7 then for i,r in ipairs(result)do if r==source then result[i]=scale(r,(old+water)/old);break end end end end
 return {recipes=result,names=names,refineries_before=oil.factory.count,refineries_after=oil.factory.count*factor,heavy=heavy,light=light}
end
function M.control(entities,ports,names)
 if not names then return 0 end
 local by_id,cells={},{}
 for _,e in ipairs(entities)do by_id[e.entity_number]=e;local p=prototypes.entity[e.name];if p.type=='pipe'or p.type=='pipe-to-ground'then cells[math.floor(e.position.x)..','..math.floor(e.position.y)]=e end end
 local count=0;local seen={};local red=defines.wire_connector_id.circuit_red
 for _,p in ipairs(ports)do local machine=by_id[p.machine]
  if machine and names[machine.recipe]==p.fluid and p.kind=='input'and not seen[p.machine]then
   local sensor=cells[p.x..','..p.y]
   if not sensor then error({'bfh.oil-overflow-sensor'},0)end
   seen[p.machine]=true
   sensor.control_behavior={circuit_mode_of_operation=defines.control_behavior.single_fluid_box.exclusive_mode.send_segment_contents}
   sensor.wires=sensor.wires or{};sensor.wires[#sensor.wires+1]={sensor.entity_number,red,machine.entity_number,red}
   local threshold=100
   for _,v in ipairs(prototypes.recipe[machine.recipe].ingredients)do if v.name==p.fluid then threshold=math.max(threshold,2*v.amount)end end
   machine.control_behavior={circuit_enabled=true,circuit_condition={first_signal={type='fluid',name=p.fluid},comparator='>',constant=threshold}}
   count=count+1
  end
 end
 return count
end
return M
