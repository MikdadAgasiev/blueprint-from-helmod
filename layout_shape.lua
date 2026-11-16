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
local work=require('generation_work')
local weights={['transport-belt']=1,['underground-belt']=4,splitter=4,pipe=1,['pipe-to-ground']=2}
work.register('trial-metrics',function(args,state)
 if not state.index then
  state.index=1;state.left=math.huge;state.top=math.huge;state.right=-math.huge;state.bottom=-math.huge;state.logistics=0
 end
 while state.index<=#args.entities do
  if not work.consume() then return false end
  local e=args.entities[state.index];local p=prototypes.entity[e.name]
  local w,h=p.tile_width,p.tile_height
  if e.direction==4 or e.direction==12 then w,h=h,w end
  state.left=math.min(state.left,e.position.x-w/2);state.right=math.max(state.right,e.position.x+w/2)
  state.top=math.min(state.top,e.position.y-h/2);state.bottom=math.max(state.bottom,e.position.y+h/2)
  state.logistics=state.logistics+(weights[p.type] or 0);state.index=state.index+1
 end
 if #args.entities==0 then return true,0,0,0 end
 local area=(state.right-state.left)*(state.bottom-state.top)
 return true,area*4+state.logistics,area,area+M.penalty(state.right-state.left,state.bottom-state.top,args.ratio)*2
end)
function M.measure(entities,ratio)
 return work.operation('trial-metrics',nil,{entities=entities,ratio=ratio},true)
end
return M
