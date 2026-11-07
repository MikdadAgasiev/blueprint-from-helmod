-- Place independent production stages side by side and order related blocks nearby.
-- Returns integer translations; entity and port transforms are applied by control.lua.
local M={}
local work=require("generation_work")
local capacity=require("capacity")
local shape=require("layout_shape")
local flow_layout=require("flow_layout")
function M.plan(blocks,gap)
  local producers,edges,parents,degree,level={},{},{},{},{}
  for i,b in ipairs(blocks) do
    edges[i]={};parents[i]={};degree[i]=0;level[i]=1
    for _,p in pairs((b.recipe_node or {}).products or {}) do
      producers[p.name]=producers[p.name] or {};producers[p.name][#producers[p.name]+1]=i
    end
  end
  for i,b in ipairs(blocks) do
    for _,p in pairs((b.recipe_node or {}).ingredients or {}) do
      for _,j in ipairs(producers[p.name] or {}) do
        if i~=j and not edges[j][i] then
          edges[j][i]=true;parents[i][j]=true;degree[i]=degree[i]+1
        end
      end
    end
  end
  -- Collapse cyclic recipe groups, rather than abandoning every other block.
  local serial,indices,low,on_stack,stack,component,components=0,{},{},{},{},{},{}
  local function visit(v)
    serial=serial+1;indices[v]=serial;low[v]=serial
    stack[#stack+1]=v;on_stack[v]=true
    for w=1,#blocks do if edges[v][w] then
      if not indices[w] then visit(w);low[v]=math.min(low[v],low[w])
      elseif on_stack[w] then low[v]=math.min(low[v],indices[w]) end
    end end
    if low[v]==indices[v] then
      local group={};components[#components+1]=group
      repeat
        local w=table.remove(stack);on_stack[w]=nil;component[w]=#components;group[#group+1]=w
      until component[v]~=nil
    end
  end
  for i=1,#blocks do if not indices[i] then visit(i) end end
  local group_edges,group_degree,group_level={},{},{}
  for i=1,#components do group_edges[i]={};group_degree[i]=0;group_level[i]=1 end
  for i=1,#blocks do for j in pairs(edges[i]) do
    local a,b=component[i],component[j]
    if a~=b and not group_edges[a][b] then group_edges[a][b]=true;group_degree[b]=group_degree[b]+1 end
  end end
  local queue={}
  for i=1,#components do if group_degree[i]==0 then queue[#queue+1]=i end end
  local head=1
  while queue[head] do
    local i=queue[head];head=head+1
    for j=1,#components do if group_edges[i][j] then
      group_level[j]=math.max(group_level[j],group_level[i]+1);group_degree[j]=group_degree[j]-1
      if group_degree[j]==0 then queue[#queue+1]=j end
    end end
  end
  for i=1,#blocks do level[i]=group_level[component[i]] end
  local layers={}
  for i=1,#blocks do
    layers[level[i]]=layers[level[i]] or {};table.insert(layers[level[i]],i)
  end
  local rank={};for i=1,#blocks do rank[i]=i end
  -- Barycentric sweeps reduce separation between suppliers and their consumers.
  for sweep=1,4 do
    local backward=sweep%2==0
    for k=1,#layers do
      local layer=layers[backward and (#layers-k+1) or k]
      local score={}
      for _,i in ipairs(layer) do
        local total,n=0,0
        for j in pairs(backward and edges[i] or parents[i]) do total=total+rank[j];n=n+1 end
        score[i]=n>0 and total/n or rank[i]
      end
      table.sort(layer,function(a,b) if score[a]==score[b] then return a<b end;return score[a]<score[b] end)
      for r,i in ipairs(layer) do rank[i]=r end
    end
  end
  local widths,heights,max_width={},{},0
  for k,layer in ipairs(layers) do
    local w,h=0,0
    for _,i in ipairs(layer) do local b=blocks[i];w=w+b.layout_width+math.max(2,math.min(gap or 8,6));h=math.max(h,b.layout_height) end
    widths[k]=math.max(0,w-math.max(2,math.min(gap or 8,6)));heights[k]=h;max_width=math.max(max_width,widths[k])
  end
  local shifts,y={},0
  for k,layer in ipairs(layers) do
    local x=math.floor((max_width-widths[k])/2)
    for _,i in ipairs(layer) do
      local b=blocks[i]
      shifts[i]={x=x-b.layout_left,y=y-b.layout_top}
      x=x+b.layout_width+math.max(2,math.min(gap or 8,6))
    end
    y=y+heights[k]+(gap or 8)
  end
  return shifts
end
-- Pack individual blocks instead of reserving a full-height production row.
-- Multiple bounded widths provide alternatives when compact geometry blocks routes.
function M.compact(blocks,gap,factor,balanced,ratio)
  gap=gap or 2
  local staged=M.plan(blocks,gap);local order={};local area,maxw=0,0
  for i,b in ipairs(blocks) do order[#order+1]=i;area=area+(b.layout_width+gap)*(b.layout_height+gap);maxw=math.max(maxw,b.layout_width) end
  table.sort(order,function(a,b)
    local ay=blocks[a].layout_top+staged[a].y;local by=blocks[b].layout_top+staged[b].y
    if ay~=by then return ay<by end
    return blocks[a].layout_left+staged[a].x<blocks[b].layout_left+staged[b].x
  end)
  local limit=math.max(maxw,math.ceil(math.sqrt(area*(ratio or 1))*(ratio and 1 or (factor or 1))))
  local placed,shifts={},{};local right,bottom=0,0
  local producers={}
  for _,i in ipairs(order) do
    local b=blocks[i];local w,h=b.layout_width,b.layout_height
    local xs,ys={[0]=true},{[0]=true}
    for _,r in pairs(placed) do xs[r.x+r.w+gap]=true;xs[math.max(0,r.x-w-gap)]=true;ys[r.y+r.h+gap]=true end
    local parents={}
    for _,v in pairs((b.recipe_node or {}).ingredients or {}) do
      for _,j in ipairs(producers[v.name] or {}) do parents[j]=true end
    end
    local best
    for x in pairs(xs) do if x+w<=limit then for y in pairs(ys) do
      local free=true
      for _,r in pairs(placed) do
        if x<r.x+r.w+gap and x+w+gap>r.x and y<r.y+r.h+gap and y+h+gap>r.y then free=false;break end
      end
      if free then
        local rr,bb=math.max(right,x+w),math.max(bottom,y+h);local distance=0
        for j in pairs(parents) do local r=placed[j];distance=distance+math.abs(x+w/2-r.x-r.w/2)+math.abs(y-r.y-r.h) end
        local score=ratio and (rr*bb+shape.penalty(rr,bb,ratio)*4+distance*2) or balanced and (bb*limit+rr*0.1+distance*0.2) or (rr*bb+distance*3+math.abs(rr-bb)*2)
        if not best or score<best.score or (score==best.score and (y<best.y or (y==best.y and x<best.x))) then best={x=x,y=y,score=score,right=rr,bottom=bb} end
      end
    end end end
    assert(best,'compact packing must permit a new bottom row')
    placed[i]={x=best.x,y=best.y,w=w,h=h};right,bottom=best.right,best.bottom
    shifts[i]={x=best.x-b.layout_left,y=best.y-b.layout_top}
    for _,v in pairs((b.recipe_node or {}).products or {}) do producers[v.name]=producers[v.name] or {};table.insert(producers[v.name],i) end
  end
  return shifts
end
-- Refine the whole two-dimensional placement, including previously placed suppliers.
-- Moving a block must not reserve the empty remainder of a production stage.
-- Only one rectangle changes during a refinement step. Keep contributions
-- between all other rectangles outside the inner search loop.
local function corridor_overlap(p,a)
 return math.max(0,math.min(p.r,a.x+a.w)-math.max(p.l,a.x))*math.max(0,math.min(p.b,a.y+a.h)-math.max(p.t,a.y))
end
local function fixed_score(rects,geometry,wires,moving)
  local c={l=math.huge,t=math.huge,r=-math.huge,b=-math.huge,distance=0,blocked=0,stubs={},corridors={}}
  for i,a in ipairs(rects) do if i~=moving then
    c.l=math.min(c.l,a.x);c.t=math.min(c.t,a.y);c.r=math.max(c.r,a.x+a.w);c.b=math.max(c.b,a.y+a.h)
    for _,p in ipairs(geometry[i][a.turn].corridors or {}) do
      local q={l=a.x+p.l,t=a.y+p.t,r=a.x+p.r,b=a.y+p.b};c.corridors[#c.corridors+1]=q
      for j,v in ipairs(rects) do if j~=i and j~=moving then c.blocked=c.blocked+corridor_overlap(q,v) end end
    end
    for _,p in ipairs(geometry[i][a.turn].stubs) do
      local x,y=a.x+p.x,a.y+p.y;c.stubs[#c.stubs+1]={x=x,y=y}
      for j,v in ipairs(rects) do if j~=i and j~=moving and x>=v.x and x<v.x+v.w and y>=v.y and y<v.y+v.h then c.blocked=c.blocked+1 end end
    end
  end end
  for _,wire in ipairs(wires) do if wire.source~=moving and wire.target~=moving then
    local a,v=rects[wire.source],rects[wire.target]
    local sp,tp=(wire.output and geometry[wire.source][a.turn].outputs[wire.output] or geometry[wire.source][a.turn].output),geometry[wire.target][v.turn].inputs[wire.input]
    c.distance=c.distance+(wire.weight or 1)*(math.abs(a.x+sp.x-v.x-tp.x)+math.abs(a.y+sp.y-v.y-tp.y))
  end end
  return c
end
local function moving_score(rects,geometry,wires,i,c,ratio,boundary)
  local a=rects[i];local l,t,r,b=math.min(c.l,a.x),math.min(c.t,a.y),math.max(c.r,a.x+a.w),math.max(c.b,a.y+a.h)
  local distance,blocked=c.distance,c.blocked
  for _,p in ipairs(c.corridors) do blocked=blocked+corridor_overlap(p,a) end
  for _,p in ipairs(geometry[i][a.turn].corridors or {}) do
    local q={l=a.x+p.l,t=a.y+p.t,r=a.x+p.r,b=a.y+p.b}
    for j,v in ipairs(rects) do if j~=i then blocked=blocked+corridor_overlap(q,v) end end
  end
  for _,p in ipairs(c.stubs) do if p.x>=a.x and p.x<a.x+a.w and p.y>=a.y and p.y<a.y+a.h then blocked=blocked+1 end end
  for _,p in ipairs(geometry[i][a.turn].stubs) do
    local x,y=a.x+p.x,a.y+p.y
    for j,v in ipairs(rects) do if i~=j and x>=v.x and x<v.x+v.w and y>=v.y and y<v.y+v.h then blocked=blocked+1 end end
  end
  for _,wire in ipairs(wires) do if wire.source==i or wire.target==i then
    local source,target=rects[wire.source],rects[wire.target]
    local sp,tp=(wire.output and geometry[wire.source][source.turn].outputs[wire.output] or geometry[wire.source][source.turn].output),geometry[wire.target][target.turn].inputs[wire.input]
    distance=distance+(wire.weight or 1)*(math.abs(source.x+sp.x-target.x-tp.x)+math.abs(source.y+sp.y-target.y-tp.y))
  end end
  local external=0
  if boundary then for j,v in ipairs(rects) do
    local g=geometry[j][v.turn]
    for _,index in ipairs(boundary.raw[j] or {}) do local p=g.inputs[index]
      local turns=math.min((p.d-4)%16,(4-p.d)%16)/4
      external=external+(v.x+p.x-l)+turns*12
    end
    local function terminal(p)
      local x,y=v.x+p.x,v.y+p.y;local side=boundary.side
      external=external+(side==0 and y-t or side==4 and r-x or side==8 and b-y or x-l)
      external=external+math.min((p.d-side)%16,(side-p.d)%16)/4*12
    end
    local ports=boundary.terminal_ports[j]
    if ports and #ports>0 then for _,index in ipairs(ports) do terminal(g.outputs[index]) end
    elseif boundary.terminal[j] and g.output then terminal(g.output) end
  end end
  return (r-l)*(b-t)*4+shape.penalty(r-l,b-t,ratio)*16+external*8+distance*6+(r-l+b-t)+blocked*1000000000000
end
local function dense_block_step(args,saved)
 local rects,blocks,geometry,wires,i,gap=args.rects,args.blocks,args.geometry,args.wires,args.i,args.gap
 saved.fixed=saved.fixed or fixed_score(rects,geometry,wires,i)
 local function score()return moving_score(rects,geometry,wires,i,saved.fixed,args.ratio,args.boundary)end
        local a=rects[i]
        if saved.ox==nil then saved.ox=a.x;saved.oy=a.y;saved.ot=a.turn end
        local ox,oy,ot=saved.ox,saved.oy,saved.ot
        if not saved.turn then saved.turn=0;saved.bx=ox;saved.by=oy;saved.bt=ot;saved.best=score() end
        while saved.turn<=3 do
          local turn=saved.turn
          a.turn=turn;a.w=turn%2==0 and blocks[i].layout_width or blocks[i].layout_height;a.h=turn%2==0 and blocks[i].layout_height or blocks[i].layout_width
          if not saved.xx then
            local xs,ys={[ox]=true,[0]=true},{[oy]=true,[0]=true}
            for j,v in ipairs(rects) do if i~=j then
              xs[v.x]=true;xs[v.x+v.w-a.w]=true;xs[v.x+v.w+gap]=true;xs[v.x-a.w-gap]=true
              ys[v.y]=true;ys[v.y+v.h-a.h]=true;ys[v.y+v.h+gap]=true;ys[v.y-a.h-gap]=true
              if args.approach then
                xs[v.x+v.w+args.approach]=true;xs[v.x-a.w-args.approach]=true
                ys[v.y+v.h+args.approach]=true;ys[v.y-a.h-args.approach]=true
                local ac=geometry[i][turn].clearance or {};local vc=geometry[j][v.turn].clearance or {}
                xs[v.x+v.w+math.max(ac[12] or 0,vc[4] or 0)]=true;xs[v.x-a.w-math.max(ac[4] or 0,vc[12] or 0)]=true
                ys[v.y+v.h+math.max(ac[0] or 0,vc[8] or 0)]=true;ys[v.y-a.h-math.max(ac[8] or 0,vc[0] or 0)]=true
              end
            end end
            -- Align actual resource ports as well as rectangle edges. Ports use
            -- cell centres, so the difference is an integer translation.
            for _,wire in ipairs(args.align_ports and wires or {}) do
              if wire.source==i or wire.target==i then
                local source,target=rects[wire.source],rects[wire.target]
                local sp=wire.output and geometry[wire.source][source.turn].outputs[wire.output] or geometry[wire.source][source.turn].output
                local tp=geometry[wire.target][target.turn].inputs[wire.input]
                if wire.source==i then
                  xs[target.x+tp.x-sp.x]=true;ys[target.y+tp.y-sp.y]=true
                else
                  xs[source.x+sp.x-tp.x]=true;ys[source.y+sp.y-tp.y]=true
                end
              end
            end
            local xx,yy={},{};for x in pairs(xs) do xx[#xx+1]=x end;for y in pairs(ys) do yy[#yy+1]=y end
            table.sort(xx);table.sort(yy)
            -- Uniform boundary samples retain the full extent, with the old
            -- position always present. Bound the Cartesian product in normal mode.
            local function sample(values,origin)
              if not args.axis_limit or #values<=args.axis_limit then return values end
              local picked={[origin]=true};local result={}
              for n=0,args.axis_limit-2 do picked[values[1+math.floor(n*(#values-1)/(args.axis_limit-2))]]=true end
              for v in pairs(picked) do result[#result+1]=v end;table.sort(result);return result
            end
            saved.xx=sample(xx,ox);saved.yy=sample(yy,oy);saved.xi=1;saved.yi=1
          end
          while saved.xi<=#saved.xx do
            local x,y=saved.xx[saved.xi],saved.yy[saved.yi]
            if not work.consume(4) then return false end
            local free=true
            for j,v in ipairs(rects) do if i~=j and x<v.x+v.w+gap and x+a.w+gap>v.x and y<v.y+v.h+gap and y+a.h+gap>v.y then free=false;break end end
            if free then
              a.x=x;a.y=y;local value=score()
              if value<saved.best then saved.bx=x;saved.by=y;saved.bt=turn;saved.best=value end
            end
            saved.yi=saved.yi+1
            if saved.yi>#saved.yy then saved.yi=1;saved.xi=saved.xi+1 end
          end
          saved.turn=turn+1;saved.xx=nil;saved.yy=nil
        end
        return true,{x=saved.bx,y=saved.by,turn=saved.bt}
end
work.register('dense-block',dense_block_step)
function M.dense(blocks,gap,factor,align_ports,ratio,thorough,boundary_side,flow_aware,approach,initial)
 return work.cached("dense-layout",function()
  local boundary
  local seeds={};local seed_blocks={}
  if boundary_side~=nil then
    local terminal_only=type(boundary_side)=='table' and boundary_side.terminal_only
    if type(boundary_side)=='table' then boundary_side=boundary_side.side end
    boundary={raw={},terminal={},terminal_ports={},side=boundary_side};local produced,consumed={},{}
    for _,b in ipairs(blocks) do
      for _,name in ipairs(b.products or {}) do produced[name]=true end
      for _,p in ipairs(b.inputs or {}) do consumed[p.ingredient]=true end
    end
    for i,b in ipairs(blocks) do
      boundary.raw[i]={}
      for index,p in ipairs(b.inputs or {}) do if not terminal_only and not produced[p.ingredient] then boundary.raw[i][#boundary.raw[i]+1]=index end end
      if not terminal_only then for _,name in ipairs(b.products or {}) do if not consumed[name] then boundary.terminal[i]=true end end end
      if b.layout_terminal_only then boundary.terminal[i]=true end
      boundary.terminal_ports[i]={};for index,p in ipairs(b.layout_output_ports or {}) do if p.graph_terminal then boundary.terminal_ports[i][#boundary.terminal_ports[i]+1]=index end end
      local best,turn
      for n=0,3 do local value=0
        for _,index in ipairs(boundary.raw[i]) do local d=((b.layout_input_dirs or {})[index] or 8)+n*4;value=value+math.min((d-4)%16,(4-d)%16) end
        if #boundary.terminal_ports[i]>0 then
         for _,index in ipairs(boundary.terminal_ports[i]) do local d=(b.layout_output_ports[index].direction or b.layout_output_dir or 8)+n*4;value=value+math.min((d-boundary_side)%16,(boundary_side-d)%16) end
        elseif boundary.terminal[i] then local d=(b.layout_output_dir or 8)+n*4;value=value+math.min((d-boundary_side)%16,(boundary_side-d)%16) end
        if not best or value<best then best=value;turn=n end
      end
      seeds[i]=turn
    end
  end
  if initial then for i,d in ipairs(initial) do seeds[i]=d.turn or 0 end end
  for i,b in ipairs(blocks) do local q={};for k,v in pairs(b) do q[k]=v end
    if (seeds[i] or 0)%2==1 then q.layout_width,q.layout_height=q.layout_height,q.layout_width end;seed_blocks[i]=q
  end
  local shifts=initial or M.compact(seed_blocks,gap,factor,true,ratio)
  local rects={}
  for i,b in ipairs(blocks) do
    rects[i]={x=b.layout_left+shifts[i].x,y=b.layout_top+shifts[i].y,w=seed_blocks[i].layout_width,h=seed_blocks[i].layout_height,turn=seeds[i] or 0}
  end
  local geometry,wires={},{}
  local vectors={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
  for i,b in ipairs(blocks) do
    geometry[i]={}
    for turn=0,3 do
      local g={stubs={},inputs={},outputs={},corridors={}};geometry[i][turn]=g
      local function point(p,d,lead)
        local x,y=p.x-b.layout_left+0.5,p.y-b.layout_top+0.5
        local w,h=b.layout_width,b.layout_height
        for t=1,turn do x,y=h-y,x;w,h=h,w end
        local v=vectors[((d or 8)+turn*4)%16]
        return {x=x+v[1]*lead,y=y+v[2]*lead,d=((d or 8)+turn*4)%16}
      end
      local function stub(p,d,sign)
        for step=0,(approach or (flow_aware and 4 or 2)) do g.stubs[#g.stubs+1]=point(p,d,sign*step) end
        if flow_aware and not approach then
          local v=vectors[((d or 8)+turn*4)%16]
          for step=1,4 do for _,side in ipairs({-1,1}) do
            local q=point(p,d,sign*step);q.x=q.x+side*v[2];q.y=q.y-side*v[1]
            g.stubs[#g.stubs+1]=q
          end end
        end
      end
      if b.product_out then g.output=point(b.product_out,b.layout_output_dir,approach or 3);stub(b.product_out,b.layout_output_dir,1) end
      for oi,p in ipairs(b.layout_output_ports or {}) do g.outputs[oi]=point(p,p.direction or b.layout_output_dir,approach or 3) end
      for ii,input in ipairs(b.inputs or {}) do
        local d=(b.layout_input_dirs or {})[ii]
        g.inputs[ii]=point(input,d,-(approach or 3));stub(input,d,-1)
      end
      if approach then
        local faces,loads,bound_counts={},{},{}
        local function demand(side,name,rate,bound)
          faces[side]=true;loads[side]=loads[side] or {};loads[side][name]=(loads[side][name] or 0)+(rate or 0);if bound then bound_counts[side]=(bound_counts[side] or 0)+1 end
        end
        if b.layout_output_ports then for _,p in ipairs(b.layout_output_ports) do
          demand(((p.direction or b.layout_output_dir or 8)+turn*4)%16,p.product or 'output',p.rate,p.flow_edge or p.graph_terminal);stub(p,p.direction or b.layout_output_dir,1)
        end elseif b.product_out then
          local side=((b.layout_output_dir or 8)+turn*4)%16
          for _,p in ipairs((b.recipe_node or {}).products or {}) do demand(side,p.name,capacity.flow(p,b.recipe_node)) end
          faces[side]=true
        end
        for ii,p in ipairs(b.inputs or {}) do local rate=p.layout_rate
          if not rate then for _,v in ipairs((b.recipe_node or {}).ingredients or {}) do if v.name==p.ingredient then rate=capacity.flow(v,b.recipe_node);break end end end
          demand((((b.layout_input_dirs or {})[ii] or p.direction or 8)+turn*4+8)%16,p.ingredient or 'input',rate,p.flow_edge)
        end
        local w,h=b.layout_width,b.layout_height;if turn%2==1 then w,h=h,w end;g.clearance={}
        for side in pairs(faces) do
          local lanes=0;if b.layout_belt_capacity then for _,rate in pairs(loads[side] or {}) do lanes=lanes+math.ceil(rate/b.layout_belt_capacity-1e-9) end end
          local bound=bound_counts[side] or 0;local depth=math.max(approach,lanes,bound+(bound>1 and 1 or 0));g.clearance[side]=depth
          if side==0 then g.corridors[#g.corridors+1]={l=-1,t=-depth,r=w+1,b=0}
          elseif side==8 then g.corridors[#g.corridors+1]={l=-1,t=h,r=w+1,b=h+depth}
          elseif side==12 then g.corridors[#g.corridors+1]={l=-depth,t=-1,r=0,b=h+1}
          else g.corridors[#g.corridors+1]={l=w,t=-1,r=w+depth,b=h+1} end
        end
      end
      for _,p in ipairs(b.layout_fluid_ports or {}) do stub(p,p.dir,1) end
      for _,p in ipairs(b.layout_belt_guards or {}) do g.stubs[#g.stubs+1]=point(p,0,0) end
    end
  end
  if flow_aware then
    local affinity={}
    for i,b in ipairs(blocks) do local a=rects[i];local g=geometry[i][a.turn];local q={recipe_node=b.recipe_node,inputs={},layout_output_ports={}}
      if g.output then q.product_out={x=a.x+g.output.x,y=a.y+g.output.y} end
      for j,p in ipairs(b.layout_output_ports or {}) do local point=g.outputs[j];local v={};for k,x in pairs(p) do v[k]=x end;v.x=a.x+point.x;v.y=a.y+point.y;q.layout_output_ports[j]=v end
      for j,p in ipairs(b.inputs or {}) do local point=g.inputs[j];q.inputs[j]={x=a.x+point.x,y=a.y+point.y,ingredient=p.ingredient,flow_edge=p.flow_edge,graph_rate=p.graph_rate,layout_rate=p.layout_rate} end
      affinity[i]=q
    end
    wires=flow_layout.wires(affinity)
  else
  for i,a in ipairs(blocks) do for j,b in ipairs(blocks) do if i~=j and a.product_out then
    for _,name in ipairs(a.products or {}) do for ii,input in ipairs(b.inputs or {}) do
      if name==input.ingredient then wires[#wires+1]={source=i,target=j,input=ii} end
    end end
  end end end
  end
  for sweep=1,(thorough and 5 or 3) do
    local changed=false
    for k=1,#rects do
      local i=sweep%2==1 and k or (#rects-k+1)
      local original={x=rects[i].x,y=rects[i].y,turn=rects[i].turn}
      local placement=work.operation('dense-block',nil,{rects=rects,blocks=blocks,geometry=geometry,wires=wires,i=i,gap=gap,align_ports=align_ports,approach=approach,ratio=ratio,axis_limit=not thorough and 16 or nil,boundary=boundary})
      local a=rects[i]
      changed=changed or placement.x~=original.x or placement.y~=original.y or placement.turn~=original.turn
      a.x=placement.x;a.y=placement.y;a.turn=placement.turn
      a.w=a.turn%2==0 and blocks[i].layout_width or blocks[i].layout_height;a.h=a.turn%2==0 and blocks[i].layout_height or blocks[i].layout_width
    end
    if not changed then break end
  end
  local left,top=math.huge,math.huge
  for _,a in ipairs(rects) do left=math.min(left,a.x);top=math.min(top,a.y) end
  for i,b in ipairs(blocks) do shifts[i]={x=rects[i].x-left-b.layout_left,y=rects[i].y-top-b.layout_top,turn=rects[i].turn} end
  return shifts
 end)
end
return M
