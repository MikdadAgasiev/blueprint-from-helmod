-- Only visible, unlocked construction items may expose equipment choices.
local M={}
function M.items(force)
 local result={}
 if force then for _,recipe in pairs(force.recipes) do
  if recipe.enabled and not recipe.hidden then
   for _,product in pairs(recipe.products) do if product.type=='item' then
    local item=prototypes.item[product.name]
    if item and not item.hidden and item.place_result then result[product.name]=item.place_result.name end
   end end
  end
 end end
 return result
end
function M.entities(force,kind)
 local result,seen={},{}
 for _,name in pairs(M.items(force)) do
  local p=prototypes.entity[name]
  if p and p.type==kind and not seen[name] then result[#result+1]=name;seen[name]=true end
 end
 table.sort(result,function(a,b)if a=='pipe' then return b~='pipe' elseif b=='pipe' then return false end;return a<b end)
 return result
end
return M
