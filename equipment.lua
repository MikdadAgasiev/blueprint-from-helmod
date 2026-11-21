-- Only visible, unlocked construction items may expose equipment choices.
local M={}
local generation_work=require('generation_work')
generation_work.register('available-items',function(args,state)
 local force=args.force
 if not state.names then
  state.names={};state.index=1;state.result={}
  if force then for name in pairs(force.recipes) do state.names[#state.names+1]=name end end
 end
 while state.index<=#state.names do
  if not generation_work.consume(4) then return false end
  local recipe=force.recipes[state.names[state.index]];state.index=state.index+1
  if recipe.enabled and not recipe.hidden then
   for _,product in pairs(recipe.products) do if product.type=='item' then
    local item=prototypes.item[product.name]
    if item and not item.hidden and item.place_result then state.result[product.name]=item.place_result.name end
   end end
  end
 end
 return true,state.result
end)
function M.items(force,excluded)
 local items=generation_work.operation('available-items',nil,{force=force},true)
 if not excluded or next(excluded)==nil then return items end
 local result={};for item,name in pairs(items) do if not excluded[name] then result[item]=name end end
 return result
end
function M.entities(force,kind,items)
 local result,seen={},{}
 for _,name in pairs(items or M.items(force)) do
  local p=prototypes.entity[name]
  if p and p.type==kind and not seen[name] then result[#result+1]=name;seen[name]=true end
 end
 table.sort(result,function(a,b)if a=='pipe' then return b~='pipe' elseif b=='pipe' then return false end;return a<b end)
 return result
end
return M
