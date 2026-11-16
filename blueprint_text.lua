local resources=require('resources')
local M={}
local side_keys={[0]='top',[4]='right',[8]='bottom',[12]='left'}
local function name(kind,value)
 if kind=='item' and resources.grade(value)~='normal' then return resources.caption(value) end
 local p=(kind=='fluid' and prototypes.fluid or kind=='recipe' and prototypes.recipe or prototypes.item)[value]
 return p and {'?',p.localised_name,value} or value
end
local function join(lines)
 if #lines==0 then return '' end
 while #lines>1 do
  local next_level={}
  for first=1,#lines,8 do
   local group={''}
   for i=first,math.min(first+7,#lines) do if i>first then group[#group+1]='\n' end;group[#group+1]=lines[i] end
   next_level[#next_level+1]=group
  end
  lines=next_level
 end
 return lines[1]
end

local function issue(text)
 local material,needed,connected=text:match('^Insufficient belt allocation: (.-) required ([%d.eE+-]+) connected ([%d.eE+-]+)$')
 if material then return {'bfh.desc-allocation-shortage',name('item',material),connected,needed} end
 local resource,recipe,x,y=text:match('^Unexpected belt resource: (.-) for (.-) at (-?%d+),(-?%d+)$')
 if resource then return {'bfh.desc-contamination',name('item',resource),name('recipe',recipe),x,y} end
 local item,xy=text:match('^Disconnected belt input: (.-) at (.+)$')
 if item then return {'bfh.desc-belt-disconnected',name('item',item),xy} end
 local fluid,where=text:match('^Disconnected fluid port: (.-) at (.+)$')
 if fluid then return {'bfh.desc-fluid-disconnected',name('fluid',fluid),where} end
 local blocked,position=text:match('^Unreachable fluid consumer: (.-) at (.+)$')
 if not blocked then blocked,position=text:match('^Wrong fluid flow direction: (.-) at (.+)$') end
 if blocked then return {'bfh.desc-fluid-direction',name('fluid',blocked),position} end
 if text:find('^Disconnected machine output:') then return {'bfh.desc-machine-output-disconnected'} end
 if text:find('^Disconnected machine feed:') then return {'bfh.desc-machine-disconnected'} end
 if text:find('^Mixed fluids:') then return {'bfh.desc-mixed-fluids'} end
 if text:find('^Disconnected fluid network:') then return {'bfh.desc-fluid-network'} end
 if text:find('^Invalid underground belt') or text:find('^Unpaired underground belt') then return {'bfh.desc-underground'} end
 if text:find('^Electricity coverage missing') or text:find('^Disconnected electricity') or text:find('^No researched supported electric pole') then return {'bfh.desc-power'} end
 return {'bfh.desc-generic-issue'}
end
function M.document(settings,interface,issues)
 local lines={{'bfh.desc-title'},{'bfh.desc-check',#issues},{'bfh.desc-reserve',settings.reserve_percent or 0}}
 if issues.fmf then lines[#lines+1]={'bfh.fmf-summary',issues.fmf.bridges,issues.fmf.ordinary} end
 for _,limit in ipairs(issues.rate_limits or {}) do lines[#lines+1]={'bfh.desc-rate-limit',name(limit.type,limit.name),string.format('%.3g',limit.produced),string.format('%.3g',limit.needed),string.format('%.3g',limit.shortfall or limit.needed-limit.produced)} end
 for _,input in ipairs(issues.imports or {}) do lines[#lines+1]={'bfh.desc-external-rate',name(input.type,input.name),string.format('%.3g',input.needed)} end
 if #(issues.unknown_rates or {})>0 then lines[#lines+1]={'bfh.desc-unknown-rates',#issues.unknown_rates} end
 if interface and #interface>0 then
  lines[#lines+1]={'bfh.desc-inputs',{'bfh.desc-side-'..side_keys[settings.input_side or 12]}}
  for i,p in ipairs(interface) do lines[#lines+1]={'',i,'. [',p.type,'=',p.name,'] ',name(p.type,p.type=='item' and resources.key(p.name,p.quality) or p.name)} end
 end
 if issues.outputs and #issues.outputs>0 then
  lines[#lines+1]={'bfh.desc-outputs',{'bfh.desc-side-'..side_keys[settings.output_side or 4]}}
  for i,p in ipairs(issues.outputs) do lines[#lines+1]={'',i,'. [',p.type,'=',p.name,'] ',name(p.type,p.type=='item' and resources.key(p.name,p.quality) or p.name),' - ',{'bfh.desc-rate',string.format('%.3g',p.rate)}} end
 end
 for i,text in ipairs(issues) do if i>12 then lines[#lines+1]='...';break end;lines[#lines+1]=issue(text) end
 return join(lines)
end
function M.apply(stack,text)
 local label,description=text:match('^([^\n]*)\n(.*)$')
 description=description or ''
 -- The engine clips this field at 500 bytes, even in the middle of UTF-8.
 -- Keep whole lines and complete characters; the summary comes first.
 if #description>500 then
  local limit=496
  while limit>0 do local next_byte=description:byte(limit+1);if not next_byte or next_byte<128 or next_byte>191 then break end;limit=limit-1 end
  local prefix=description:sub(1,limit);local last=prefix:match('.*()\n')
  description=(last and prefix:sub(1,last-1) or prefix)..'\n...'
 end
 stack.label=label or text;stack.blueprint_description=description
end
function M.fallback(locale,settings,interface,issues)
 local ru=locale=='ru';local sides=ru and {[0]='сверху',[4]='справа',[8]='снизу',[12]='слева'} or {[0]='top',[4]='right',[8]='bottom',[12]='left'}
 local lines={ru and 'Чертёж из Helmod' or 'Blueprint from Helmod'}
 for _,v in ipairs(issues.rate_limits or {}) do
  lines[#lines+1]=(ru and 'Дефицит ' or 'Shortfall ')..v.name..': '..string.format('%.3g',v.shortfall or v.needed-v.produced)..(ru and '/с' or '/s')
 end
 for _,v in ipairs(issues.imports or {}) do
  lines[#lines+1]=(ru and 'Внешняя подача ' or 'External supply ')..v.name..': '..string.format('%.3g',v.needed)..(ru and '/с' or '/s')
 end
 if #(issues.unknown_rates or {})>0 then lines[#lines+1]=(ru and 'Неизвестные расходы: ' or 'Unknown rates: ')..#issues.unknown_rates end
 for _,g in ipairs({{ports=interface,title=ru and 'Вводы' or 'Inputs',side=settings.input_side or 12},{ports=issues.outputs,title=ru and 'Выводы' or 'Outputs',side=settings.output_side or 4}}) do if g.ports and #g.ports>0 then
  lines[#lines+1]=g.title..' ('..sides[g.side]..'):'
  for i,p in ipairs(g.ports) do lines[#lines+1]=i..'. ['..p.type..'='..p.name..'] '..p.name..(p.quality and p.quality~='normal' and (' / '..p.quality) or '')..(p.rate and (' - '..string.format('%.3g',p.rate)..(ru and '/с' or '/s')) or '') end
 end end
 lines[#lines+1]=(ru and 'Проверка соединений: проблем — ' or 'Connection issues: ')..#issues
 lines[#lines+1]=(ru and 'Запас промежуточного производства: ' or 'Intermediate production reserve: ')..(settings.reserve_percent or 0)..'%'
 return table.concat(lines,'\n')
end
return M
