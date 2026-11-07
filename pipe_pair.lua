local M={}
local function categories(p,kind)
 local out={}
 for _,fb in pairs(p.fluidbox_prototypes or {}) do
  for _,c in ipairs(fb.pipe_connections) do if c.connection_type==kind then
   for _,name in ipairs(c.connection_category) do out[name]=true end
  end end
 end
 return out
end
local function compatible(pipe,ug)
 if not ug or ug.type~='pipe-to-ground' or ug.tile_width~=1 or ug.tile_height~=1 then return false end
 local a,b=categories(pipe,'normal'),categories(ug,'normal')
 for name in pairs(a) do if b[name] then return true end end
 return false
end
function M.resolve(name)
 local p=prototypes.entity[name]
 if not p or p.type~='pipe' then return nil,0,'invalid surface pipe' end
 local guesses={}
 if name=='pipe' then guesses[1]='pipe-to-ground' else
  local stem=name:gsub('%-pipe$','-pipe-to-ground')
  if stem~=name then guesses[#guesses+1]=stem end
  guesses[#guesses+1]=name..'-to-ground'
 end
 for _,candidate in ipairs(guesses) do
  local q=prototypes.entity[candidate]
  if compatible(p,q) then
   local distance
   for _,fb in pairs(q.fluidbox_prototypes) do for _,c in ipairs(fb.pipe_connections) do
    if c.connection_type=='underground' and c.max_underground_distance then
     distance=math.min(distance or math.huge,c.max_underground_distance)
    end
   end end
   if distance then return candidate,distance end
  end
 end
 return nil,0,'no unambiguous compatible underground pipe'
end
return M
