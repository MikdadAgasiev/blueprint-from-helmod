-- Join FMF-only internal junctions without a default-pipe/pump round trip.
local M={}
local work=require('generation_work')
local graph=require('fluid_graph')
local V={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
local function key(x,y)return x..','..y end
local function ports(e)
 local result={};local turn=e.direction or 0
 for _,fb in pairs(prototypes.entity[e.name].fluidbox_prototypes or {})do for _,c in ipairs(fb.pipe_connections)do
  local p=c.positions and c.positions[turn/4+1]
  if p and c.connection_type=='normal'then local d=(c.direction+turn)%16
   result[#result+1]={x=math.floor(e.position.x+p.x),y=math.floor(e.position.y+p.y),d=d,category=c.connection_category[1]}
  end
 end end
 return result
end
local function cells(e,fn)
 local p=prototypes.entity[e.name];local w,h=p.tile_width,p.tile_height
 if (e.direction or 0)%8==4 then w,h=h,w end
 for x=math.floor(e.position.x-w/2+.001),math.ceil(e.position.x+w/2-.001)-1 do
  for y=math.floor(e.position.y-h/2+.001),math.ceil(e.position.y+h/2-.001)-1 do if fn(x,y)==false then return false end end
 end
 return true
end
local function shapes(catalog,n)
 local result={}
 if n==2 then result[#result+1]={name='straight',dirs={0,8}};result[#result+1]={name='straight',dirs={4,12}}end
 for _,name in ipairs({'duct-curve','duct-t-junction','duct-cross'})do local ds=(catalog.junctions or {})[name]
  if ds and #ds==n then for turn=0,3 do local q={name=name,turn=turn*4,dirs={}};for _,d in ipairs(ds)do q.dirs[#q.dirs+1]=(d+turn*4)%16 end;result[#result+1]=q end end
 end
 return result
end
local function pieces(terminal,jx,jy,jd,result)
 local td=terminal.d;local tv,jv=V[td],V[jd]
 local vertical=td%8==0;local same=jd%8==td%8
 -- Outside duct's boundary: east/south openings end one tile after their cell.
 local bx=terminal.x+(td==4 and 1 or 0);local by=terminal.y+(td==8 and 1 or 0)
 local function straight(ax,ay,zx,zy,d)
  local v=V[d];local length=(zx-ax)*v[1]+(zy-ay)*v[2]
  if length<0 or math.abs(length-math.floor(length+.5))>.001 then return false end
  for i=0,length-1 do result[#result+1]={name='duct-small',direction=d%8==0 and 0 or 4,position={x=ax+v[1]*(i+.5),y=ay+v[2]*(i+.5)}}end
  return true
 end
 if same then
  if jd~=(td+8)%16 or (vertical and terminal.x~=jx)or(not vertical and terminal.y~=jy)then return false end
  return straight(bx,by,jx+jv[1],jy+jv[2],td)
 end
 local cx,cy=vertical and terminal.x or jx,vertical and jy or terminal.y
 if not straight(bx,by,cx-tv[1],cy-tv[2],td)then return false end
 local back,forward=(td+8)%16,(jd+8)%16;local turn
 for t=0,3 do local a,b=t*4,(12+t*4)%16;if(a==back and b==forward)or(a==forward and b==back)then turn=t*4;break end end
 result[#result+1]={name='duct-curve',direction=turn,position={x=cx,y=cy}}
 return straight(cx-jv[1],cy-jv[2],jx+jv[1],jy+jv[2],forward)
end
local function step(a,s)
 if not s.phase then
  s.phase='index';s.i=1;s.nodes={};s.normal={};s.occupied={};s.changed={};s.added={};s.next_id=a.en;s.junctions=0;s.transitions=0
  s.protected={};for _,p in ipairs(a.ports)do s.protected[key(p.x,p.y)]=true end
 end
 if s.phase=='index'then
  while s.i<=#a.entities do
   if not work.consume(8)then return false end
   local i=s.i;s.i=i+1;local e=a.entities[i];local openings=ports(e)
   cells(e,function(x,y)s.occupied[key(x,y)]=i end)
   for _,p in ipairs(openings)do p.index=i;local k=key(p.x,p.y)..'/'..p.d;s.normal[k]=s.normal[k]or{};s.normal[k][#s.normal[k]+1]=p end
   if e.name==a.catalog.pipe or e.name==a.catalog.underground or e.name=='duct-intake'or e.name=='duct-exhaust'then
    s.nodes[i]={ports=openings,adj={},adapter=e.name=='duct-intake'or e.name=='duct-exhaust',protected=e.control_behavior~=nil or e.wires~=nil}
    if s.protected[key(math.floor(e.position.x),math.floor(e.position.y))]then s.nodes[i].protected=true end
   end
  end
  s.order={};for i in pairs(s.nodes)do s.order[#s.order+1]=i end;table.sort(s.order);s.i=1;s.phase='edges'
 end
 if s.phase=='edges'then
  while s.i<=#s.order do
   if not work.consume(8)then return false end
   local i=s.order[s.i];s.i=s.i+1;local n=s.nodes[i]
   for _,p in ipairs(n.ports)do if p.category=='default'then local v=V[p.d]
    for _,q in ipairs(s.normal[key(p.x+v[1],p.y+v[2])..'/'..((p.d+8)%16)]or{})do if q.category=='default'and s.nodes[q.index]then n.adj[q.index]=true end end
   end end
   local e=a.entities[i]
   if e.name==a.catalog.underground then local d=((e.direction or 0)+8)%16;local v=V[d]
    for length=1,a.catalog.distance do local x,y=math.floor(e.position.x)+v[1]*length,math.floor(e.position.y)+v[2]*length
     local j=s.occupied[key(x,y)];local other=j and a.entities[j]
     if other and other.name==a.catalog.underground and ((other.direction or 0)+8)%16==(d+8)%16 then n.adj[j]=true;break end
    end
   end
  end
  s.seen={};s.islands={};s.i=1;s.phase='islands'
 end
 if s.phase=='islands'then
  while s.i<=#s.order do
   local i=s.order[s.i]
   if s.seen[i]then s.i=s.i+1 else
    s.island=s.island or {queue={i},head=1,remove={},terminals={},xs={},ys={},valid=true};local c=s.island;s.seen[i]=true
    while c.queue[c.head]do
     if not work.consume(8)then return false end
     local j=c.queue[c.head];c.head=c.head+1;local n=s.nodes[j];local e=a.entities[j];c.remove[j]=true
     if n.protected then c.valid=false end
     if n.adapter then
      for _,p in ipairs(n.ports)do if p.category=='ducts'then local v=V[p.d];local matches=s.normal[key(p.x+v[1],p.y+v[2])..'/'..((p.d+8)%16)]or{}
       local target;for _,q in ipairs(matches)do if q.category=='ducts'and not s.nodes[q.index]then target=q;break end end
       if not target then c.valid=false else c.terminals[#c.terminals+1]=target end
      end end
      for offset=-2,2 do c.xs[math.floor(e.position.x)+offset]=true;c.ys[math.floor(e.position.y)+offset]=true end
     end
     for q in pairs(n.adj)do if not s.seen[q]then s.seen[q]=true;c.queue[#c.queue+1]=q end end
    end
    if c.valid and #c.terminals>=2 and #c.terminals<=4 then s.islands[#s.islands+1]=c end
    s.island=nil;s.i=s.i+1
   end
  end
  s.i=1;s.phase='plan'
 end
 while s.i<=#s.islands do local c=s.islands[s.i]
  if not c.options then
   c.options={};local xs,ys={},{};for x in pairs(c.xs)do xs[#xs+1]=x end;for y in pairs(c.ys)do ys[#ys+1]=y end;table.sort(xs);table.sort(ys)
   local variants=shapes(a.catalog,#c.terminals)
   if not(a.catalog.junctions or {})['duct-curve']then variants={}end
   local function permutation(ds,path,used)
    if #path==#ds then local result={};for _,d in ipairs(path)do result[#result+1]=d end;return {result}end
    local result={};for i,d in ipairs(ds)do if not used[i]then used[i]=true;path[#path+1]=d;for _,p in ipairs(permutation(ds,path,used))do result[#result+1]=p end;path[#path]=nil;used[i]=nil end end;return result
   end
   for _,v in ipairs(variants)do for _,ds in ipairs(permutation(v.dirs,{},{}))do for _,x in ipairs(xs)do for _,y in ipairs(ys)do c.options[#c.options+1]={shape=v,dirs=ds,x=x,y=y}end end end end
   c.option=1
  end
  while c.option<=#c.options do
   if not work.consume(32)then return false end
   local o=c.options[c.option];c.option=c.option+1;local es={};local ok=true
   if o.shape.name=='straight'then local v=V[o.dirs[1]];for _,sign in ipairs({-.5,.5})do es[#es+1]={name='duct-small',direction=o.dirs[1]%8==0 and 0 or 4,position={x=o.x+v[1]*sign,y=o.y+v[2]*sign}}end
   else es[1]={name=o.shape.name,direction=o.shape.turn,position={x=o.x,y=o.y}}end
   for i,t in ipairs(c.terminals)do if not pieces(t,o.x,o.y,o.dirs[i],es)then ok=false;break end end
   if ok and(not c.best or #es<#c.best)then
    local occupied,normal={},{}
    for _,e in ipairs(es)do
     if not cells(e,function(x,y)local k=key(x,y);local owner=s.occupied[k];if occupied[k]or(owner and not c.remove[owner])then return false end;occupied[k]=true end)then ok=false;break end
     for _,p in ipairs(ports(e))do
      normal[key(p.x,p.y)..'/'..p.d]=true
      local v=V[p.d]
      for _,q in ipairs(s.normal[key(p.x+v[1],p.y+v[2])..'/'..((p.d+8)%16)]or{})do
       if q.category==p.category and not c.remove[q.index]and not s.changed[q.index]then
        local allowed=false;for _,t in ipairs(c.terminals)do if q==t then allowed=true;break end end
        if not allowed then ok=false end
       end
      end
     end
    end
    if ok then for _,t in ipairs(c.terminals)do local v=V[t.d];if not normal[key(t.x+v[1],t.y+v[2])..'/'..((t.d+8)%16)]then ok=false;break end end end
    if ok then c.best=es end
   end
  end
  if c.best then
   c.check=c.check or {};c.entities=c.entities or {}
   if #c.entities==0 then
    for i,e in ipairs(a.entities)do if not s.changed[i]and not c.remove[i]then c.entities[#c.entities+1]=e end end
    for _,e in ipairs(s.added)do c.entities[#c.entities+1]=e end
    for i,e in ipairs(c.best)do e.entity_number=s.next_id+i-1;c.entities[#c.entities+1]=e end
   end
   local done,issues=graph.step({entities=c.entities,ports=a.ports,independent=a.independent},c.check)
   if not done then return false end
   if #issues==0 then
    for i in pairs(c.remove)do s.changed[i]=true end
    for _,e in ipairs(c.best)do
     s.added[#s.added+1]=e;cells(e,function(x,y)s.occupied[key(x,y)]=-#s.added end)
     for _,p in ipairs(ports(e))do p.index=-#s.added;local k=key(p.x,p.y)..'/'..p.d;s.normal[k]=s.normal[k]or{};s.normal[k][#s.normal[k]+1]=p end
    end
    s.next_id=s.next_id+#c.best;s.junctions=s.junctions+1;s.transitions=s.transitions+#c.terminals
   end
  end
  s.i=s.i+1
 end
 local result={};for i,e in ipairs(a.entities)do if not s.changed[i]then result[#result+1]=e end end;for _,e in ipairs(s.added)do result[#result+1]=e end
 return true,result,s.next_id,{junctions=s.junctions,transitions_removed=s.transitions}
end
work.register('fmf-junctions',step)
function M.coalesce(entities,ports,en,catalog,independent)
 return work.operation('fmf-junctions',nil,{entities=entities,ports=ports,en=en,catalog=catalog,independent=independent})
end
return M
