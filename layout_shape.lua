-- Shape is expressed in world coordinates, independently of the input side.
local M={}
local orientation=require('orientation')
function M.ratio(settings)
 if settings.link_mode=='independent' then return nil end
 local shape=settings.layout_shape
 local ratio=shape=='square' and 1 or shape=='horizontal' and 2.5 or shape=='vertical' and 0.4
 if ratio and orientation.turns(settings)%2==1 then ratio=1/ratio end
 return ratio
end
function M.penalty(w,h,ratio)
 if not ratio then return 0 end
 return (w-ratio*h)^2/ratio
end
function M.rank(entities,area,ratio)
 if not ratio then return area end
 local l,t,r,b=math.huge,math.huge,-math.huge,-math.huge
 for _,e in ipairs(entities) do
  local p=prototypes.entity[e.name];local w,h=p and p.tile_width or 1,p and p.tile_height or 1
  if (e.direction or 0)%8==4 then w,h=h,w end
  l=math.min(l,e.position.x-w/2);r=math.max(r,e.position.x+w/2)
  t=math.min(t,e.position.y-h/2);b=math.max(b,e.position.y+h/2)
 end
 return area+M.penalty(r-l,b-t,ratio)*2
end
return M
