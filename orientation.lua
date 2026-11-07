local M={}
function M.turns(settings)
 if settings.link_mode=='independent' then return 0 end
 return math.floor(((settings.input_side or 12)-12)/4)%4
end
function M.output(settings)
 return ((settings.output_side or 4)-M.turns(settings)*4)%16
end
function M.point(p,n,cell)
 local x,y=p.x,p.y
 for _=1,n%4 do x,y=-y-(cell and 1 or 0),x end
 return {x=x,y=y}
end
function M.entity(e,n)
 e.position=M.point(e.position,n,false);e.direction=((e.direction or 0)+4*n)%16
 for _,field in ipairs({'pickup_position','drop_position'}) do if e[field] then e[field]=M.point(e[field],n,false) end end
end
function M.port(p,n)
 local q=M.point(p,n,true);p.x,p.y=q.x,q.y
 if p.direction~=nil then p.direction=(p.direction+4*n)%16 end
 if p.dir~=nil then p.dir=(p.dir+4*n)%16 end
end
function M.finish(entities,interface,outputs,settings)
 local n=M.turns(settings)
 if n==0 then return end
 for _,e in ipairs(entities) do M.entity(e,n) end
 for _,p in ipairs(interface or {}) do M.port(p,n) end
 local seen={}
 for _,p in ipairs(outputs or {}) do
  M.port(p,n)
  for _,s in ipairs(p.sources or {}) do if not seen[s] then M.port(s,n);seen[s]=true end end
 end
end
return M
