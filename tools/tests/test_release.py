import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tools/tests").mkdir(parents=True)
        self.values = {"info.json": json.dumps({"name": release.MOD, "version": "1.0.0"}).encode(),
                       "control.lua": b"return 1\n", "README.md": b"English description\n"}
        for n, data in self.values.items():
            (self.root / n).write_bytes(data)
        (self.root / "tools/package-files.json").write_text(json.dumps(list(self.values)))

    def tearDown(self):
        self.tmp.cleanup()

    def test_shallow_self_intersection_gets_one_bounded_cycle_retry(self):
        from lupa.lua52 import LuaRuntime
        root=TOOLS.parent.as_posix()
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(root+"/?.lua;")+"..package.path")
        lua.execute("""
          local work=require('generation_work');local calls=0
          work.operation=function(_,_,o)
            calls=calls+1
            if o.avoid_cycles then return {{x=1,y=1}} end
            return nil,'self-intersection'
          end
          local router=require('routing')
          assert(router.plan{context={},shallow=true,max_states=3000})
          assert(calls==2)
          calls=0
          work.operation=function(_,_,o)
            calls=calls+1;assert(not o.exhaustive);return nil,'self-intersection'
          end
          assert(not router.plan{context={},shallow=true,max_states=3000})
          assert(calls==2)
          calls=0
          work.operation=function()calls=calls+1;return nil,'no-path'end
          assert(not router.plan{context={},shallow=true})
          assert(calls==1)
        """)

    def test_package_is_exact_deterministic_and_excludes_private_files(self):
        (self.root / "AGENTS.md").write_text("private rules")
        (self.root / ".env").write_text("not a real secret")
        first = release.package(self.root / "out", self.values, "1.0.0")
        second = release.package(self.root / "other", self.values, "1.0.0")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertTrue(release.zip_matches(first, self.values, "1.0.0"))
        with ZipFile(first) as z:
            self.assertEqual(len(z.namelist()), 3)
            self.assertFalse(any("AGENTS" in n or ".env" in n for n in z.namelist()))

    def test_published_version_never_overwritten(self):
        path = release.package(self.root / "out", self.values, "1.0.0")
        original = path.read_bytes()
        changed = dict(self.values, **{"control.lua": b"return 2"})
        with self.assertRaises(release.ReleaseError):
            release.package(self.root / "out", changed, "1.0.0")
        self.assertEqual(path.read_bytes(), original)

    def test_reuse_preserves_original_checked_zip_bytes(self):
        path = self.root / "out" / f"{release.MOD}_1.0.0.zip"
        path.parent.mkdir()
        with ZipFile(path, "w") as z:
            for n, data in self.values.items():
                z.writestr(f"{release.MOD}_1.0.0/" + n, data)
        before = path.read_bytes()
        self.assertEqual(release.package(path.parent, self.values, "1.0.0").read_bytes(), before)

    def test_allowlist_rejects_traversal_and_private_rules(self):
        for bad in ("../outside", "/absolute", "folder\\file", "AGENTS.md"):
            (self.root / "AGENTS.md").write_text("private")
            (self.root / "tools/package-files.json").write_text(json.dumps(list(self.values) + [bad]))
            with self.assertRaises(release.ReleaseError):
                release.files(self.root)

    def test_new_module_cannot_be_silently_omitted(self):
        (self.root / "new.lua").write_text("return 3")
        with self.assertRaises(release.ReleaseError):
            release.files(self.root)

    def test_syntax_checks_real_lua_52(self):
        release.syntax(self.values)
        with self.assertRaises(Exception):
            release.syntax({"broken.lua": b"local = nope"})

    def test_fingerprint_changes_on_bytes_and_paths(self):
        self.assertNotEqual(release.fingerprint({"a": b"same"}), release.fingerprint({"b": b"same"}))
        self.assertNotEqual(release.fingerprint({"a": b"same"}), release.fingerprint({"a": b"different"}))

    def test_cache_reuses_only_same_source_and_test_code(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"), patch.object(release.Runner, "command") as command:
            r = release.Runner(root=self.root)
            r.config = {"output": str(self.root / "out")}
            r.check()
            self.assertEqual(command.call_count, 1)
            r.check()
            self.assertEqual(command.call_count, 1)
            (self.root / "tools/test_helper.py").write_text("# changed regression")
            r.check()
            self.assertEqual(command.call_count, 2)

    def test_graphify_accepts_only_explicit_gate_for_exact_commit(self):
        good = {"user": {"login": "graphify-labs[bot]"}, "commit_id": "abc", "state": "COMMENTED",
                "body": "<!-- graphify-inline:abc -->\n**No blocking issues.**\n## graphify gate\n**PASS** — objectively clean"}
        self.assertTrue(release.graphify_pass([good], "abc"))
        for update in ({"commit_id": "old"}, {"user": {"login": "someone"}},
                       {"state": "DISMISSED"}, {"body": "PASS"},
                       {"body": good["body"] + "\n**FAIL**"}, {"state": "CHANGES_REQUESTED"}):
            self.assertFalse(release.graphify_pass([{**good, **update}], "abc"), update)

    def test_graphify_real_gate_does_not_require_optional_summary_phrase(self):
        review = {"user": {"login": "graphify-labs[bot]"}, "commit_id": "abc", "state": "COMMENTED",
                  "body": "Worth a look.\n## graphify gate\n\n**PASS** - objectively clean"}
        self.assertTrue(release.graphify_pass([review], "abc"))

    def test_manual_review_is_bound_to_snapshot_and_reason(self):
        review = {"snapshot": "abc", "outcome": "PASS", "reason": "Graphify monthly quota exhausted",
                  "reviewer": "Codex", "notes": "Reviewed release changes and regressions"}
        self.assertTrue(release.manual_review_pass(review, "abc"))
        self.assertFalse(release.manual_review_pass(review, "different"))
        for key in review:
            self.assertFalse(release.manual_review_pass({k:v for k,v in review.items() if k != key}, "abc"))

    def test_oil_balance_adds_researched_cracking_without_liquid_surplus(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
         prototypes={recipe={
          ['heavy-oil-cracking']={categories={'chemistry'},energy=2,ingredients={{type='fluid',name='heavy-oil',amount=40},{type='fluid',name='water',amount=30}},products={{type='fluid',name='light-oil',amount=30}}},
          ['light-oil-cracking']={categories={'chemistry'},energy=2,ingredients={{type='fluid',name='light-oil',amount=30},{type='fluid',name='water',amount=30}},products={{type='fluid',name='petroleum-gas',amount=20}}}},
          entity={plant={type='assembling-machine',crafting_categories={chemistry=true},get_crafting_speed=function()return 1 end}},item={plant={place_result={name='plant'}}}}
         local force={recipes={plant={enabled=true,products={{type='item',name='plant'}}},['heavy-oil-cracking']={enabled=true,products={}},['light-oil-cracking']={enabled=true,products={}}}}
         local function f(name,amount)return {type='fluid',name=name,amount=amount,count=amount}end
         local recipes={{name='science',count=1,base_time=1,factory={name='plant',count=1},ingredients={f('petroleum-gas',130.3125),f('light-oil',2.1875)},products={{type='item',name='science',amount=1,count=1}}},
          {name='advanced-oil-processing',count=4.34375,base_time=1,factory={name='refinery',count=21.71875},ingredients={f('water',217.1875),f('crude-oil',434.375)},products={f('heavy-oil',86.875),f('light-oil',304.0625),f('petroleum-gas',130.3125)}}}
         local original=require('generation_work').copy(recipes)
         local oil=require('oil_balance');local result=oil.apply(recipes,force,{})
         assert(result.names and #result.recipes==4 and result.refineries_after<8 and result.refineries_after>7)
         local balance={};for _,r in ipairs(result.recipes)do for _,side in ipairs({'ingredients','products'})do for _,v in ipairs(r[side]or{})do if v.type=='fluid'then balance[v.name]=(balance[v.name]or 0)+(side=='products'and 1 or -1)*v.count end end end end
         for _,name in ipairs({'heavy-oil','light-oil','petroleum-gas'})do assert(math.abs(balance[name])<1e-6,name..' is unbalanced')end
         assert(recipes[2].factory.count==original[2].factory.count and recipes[1].products[1].count==1,'Original plan mutated')
         defines={wire_connector_id={circuit_red=1},control_behavior={single_fluid_box={exclusive_mode={send_segment_contents=1}}}}
         prototypes.entity.pipe={type='pipe'}
         local es={{entity_number=1,name='plant',recipe='heavy-oil-cracking',position={x=3.5,y=3.5}},{entity_number=2,name='pipe',position={x=.5,y=.5}}}
         assert(oil.control(es,{{x=0,y=0,machine=1,kind='input',fluid='heavy-oil'}},result.names)==1)
         assert(es[1].control_behavior.circuit_enabled and es[1].control_behavior.circuit_condition.first_signal.name=='heavy-oil'and #es[2].wires==1)
         local repeated=oil.apply(result.recipes,force,{});assert(repeated.names and #repeated.recipes==4,'Existing cracking must not be duplicated')
         recipes[1].factory.name='assembler';local fallback=oil.apply(recipes,force,{});assert(fallback.names,'Researched chemical plant fallback missing');recipes[1].factory.name='plant'
         local unknown=require('generation_work').copy(recipes);unknown[1].ingredients[1].rate_unknown=true;assert(not oil.apply(unknown,force,{}).names,'Unknown flow must not be guessed')
         force.recipes['light-oil-cracking'].enabled=false;assert(oil.apply(recipes,force,{}).recipes==recipes,'Unresearched recipe added')
         force.recipes['light-oil-cracking'].enabled=true;assert(oil.apply(recipes,force,{link_mode='independent'}).recipes==recipes)
         assert(oil.apply({recipes[2]},force,{}).recipes[1]==recipes[2],'Explicit refinery target changed')
        """)

    def test_fluid_display_labels_preserve_pipes_and_leave_inlet_access(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
         script={active_mods={DisplayPlatesForked='1.7.0'}}
         prototypes={entity={pipe={tile_width=1,tile_height=1,type='pipe'},['copper-display-small']={tile_width=1,tile_height=1,type='simple-entity-with-owner'}}}
         for _,mode in ipairs({'connected','legacy','derived'})do local independent=mode~='connected'
          local es={{entity_number=1,name='pipe',position={x=.5,y=.5}}}
          local inlet={x=0,y=0,name='water',type='fluid',direction=4}
          local blocks={{fluid_inputs={{x=0,y_top=0,y_bot=10,ingredient='water',dir=4}}}}
          local count,missing=require('display_plates').add(es,blocks,not independent and {inlet}or nil,{pipe='pipe'},function()error('Fluid label must not request a belt tunnel')end,function()end,mode=='derived'and {{x=0,y=0,fluid='water',kind='input',dir=4,block=1},{x=0,y=5,fluid='water',kind='input',dir=4,block=1}}or nil)
          assert(count==1 and missing==0 and #es==2)
          assert(es[1].name=='pipe'and es[1].position.x==.5 and es[1].position.y==.5 and inlet.x==0)
          assert(es[2].icon.type=='fluid'and es[2].icon.name=='water'and es[2].icon.quality==nil)
          assert(es[2].position.x==.5 and math.abs(es[2].position.y-.5)==1,'Label must be beside the inlet')
         end
        """)

    def test_normal_transport_quality_survives_hidden_quality_feature(self):
        from lupa.lua52 import LuaRuntime
        lua = LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("prototypes={quality={normal={hidden=true,level=0},uncommon={hidden=false,level=1},hidden={hidden=true,level=9}}}")
        quality = lua.eval("require('transport_quality')")
        locked = lua.eval("{is_quality_unlocked=function() return false end}")
        available = quality.available(locked)
        self.assertEqual([available[i] for i in range(1, len(available)+1)], ['normal'])
        unlocked = lua.eval("{is_quality_unlocked=function() return true end}")
        available = quality.available(unlocked)
        self.assertEqual([available[i] for i in range(1, len(available)+1)], ['normal','uncommon'])

    def test_fluid_replay_completes_without_recopying_finished_paths(self):
        from lupa.lua52 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        ticks, entities = lua.execute(r"""

local work=require('generation_work');local fluids=require('fluids')
prototypes={entity={pipe={type='pipe',tile_width=1,tile_height=1,fluidbox_prototypes={}},box={tile_width=1,tile_height=1}}}
local base={entities={{entity_number=1,name='box',position={x=0.5,y=20.5}},{entity_number=2,name='box',position={x=70.5,y=20.5}}},ports={},padding={}}
for i=1,12 do base.ports[i]={x=(i-1)*5,y=0,dir=4,external=true,kind='input',fluid='water',block=i} end
for i=1,700 do base.padding[i]={a=i,b=i,c={x=i,y=i}} end
local cache={}
for tick=1,500 do
 work.begin(cache,64)
 local ok,out=pcall(function()
  work.resume_pending();work.replay()
  return work.cached('parent',function()
   local w=work.fork('input',base)
   local en,fail=fluids.route(w.entities,w.ports,3,{pipe='pipe'},function()end)
   assert(fail==0,'fluid routing failed')
   return {entities=w.entities,en=en}
  end,true)
 end)
 work.finish()
 if ok then return tick,#out.entities end
 assert(work.is_pending(out),tostring(out))
end
return false,cache.work_units

""")
        self.assertIsNot(ticks, False, "Fluid routing replay made no bounded progress")
        self.assertLessEqual(ticks, 500)
        self.assertEqual(entities, 58)

    def test_goal_index_matches_exhaustive_manhattan_distance(self):
        from lupa.lua52 import LuaRuntime
        import random
        lua = LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        goals = lua.eval("require('goal_distance')")
        rng = random.Random(124)
        for size in [1, 2, 10, 100, 500]:
            points = [(rng.randrange(-100,101), rng.randrange(-100,101)) for _ in range(size)]
            tree = goals.build(lua.table_from([lua.table_from(p) for p in points]))
            for _ in range(100):
                x,y = rng.randrange(-150,151),rng.randrange(-150,151)
                expected = min(abs(x-a)+abs(y-b) for a,b in points)
                self.assertEqual(goals.distance(tree,x,y),expected)

    def _fmf_runtime(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
         prototypes={entity={}}
         local function proto(name,w,h,kind,connections)
          local cs={}
          for _,v in ipairs(connections)do
           local positions={};local x,y=v[2],v[3]
           for i=1,4 do positions[i]={x=x,y=y};x,y=-y,x end
           cs[#cs+1]={direction=v[1],positions=positions,connection_type='normal',connection_category={v[4]or'ducts'},flow_direction=v[5]or'input-output'}
          end
          prototypes.entity[name]={type=kind,tile_width=w,tile_height=h,fluidbox_prototypes={{pipe_connections=cs}}}
         end
         proto('pipe',1,1,'pipe',{{0,0,0,'default'},{4,0,0,'default'},{8,0,0,'default'},{12,0,0,'default'}})
         proto('duct',2,2,'storage-tank',{{0,0,-.5},{8,0,.5}})
         proto('duct-small',2,1,'storage-tank',{{0,0,-.25},{8,0,.25}})
         proto('duct-long',2,4,'storage-tank',{{0,0,-1.5},{8,0,1.5}})
         proto('duct-curve',2,2,'storage-tank',{{0,0,-.5},{12,-.5,0}})
         proto('duct-t-junction',2,2,'storage-tank',{{0,0,-.5},{4,.5,0},{12,-.5,0}})
         proto('duct-cross',2,2,'storage-tank',{{0,0,-.5},{4,.5,0},{8,0,.5},{12,-.5,0}})
         local default={{4,.5,-.5},{4,.5,.5},{8,.5,.5},{8,-.5,.5},{12,-.5,-.5},{12,-.5,.5}}
         local ins={{0,0,-.5,'ducts','output'}};for _,p in ipairs(default)do ins[#ins+1]={p[1],p[2],p[3],'default','input'}end
         proto('duct-intake',2,2,'pump',ins)
         local exhaust={{8,0,.5,'ducts','input'},{0,.5,-.5,'default','output'},{0,-.5,-.5,'default','output'},{4,.5,-.5,'default','output'},{4,.5,.5,'default','output'},{12,-.5,-.5,'default','output'},{12,-.5,.5,'default','output'}}
         proto('duct-exhaust',2,2,'pump',exhaust)
         proto('pump',1,2,'pump',{{0,0,-.5,'default','output'},{8,0,.5,'default','input'}})
         catalog={pipe='pipe',underground='ug',distance=10,limit=3000,pump_capacity=1200,ordinary_extent=320,
          junctions={['duct-curve']={0,12},['duct-t-junction']={0,4,12},['duct-cross']={0,4,8,12}}}
        """)
        return lua

    def test_fmf_does_not_cosmetically_replace_a_sufficient_native_pipeline(self):
        lua=self._fmf_runtime()
        lua.execute("""
         local es={};for x=0,100 do es[#es+1]={entity_number=#es+1,name='pipe',position={x=x+.5,y=.5}}end
         local result,id,status=require('fmf').promote(es,{},102,{},catalog)
         assert(result==es and id==102 and status.not_required and status.bridges==0)
        """)

    def test_long_native_pipeline_prefers_a_pump_and_uses_fmf_for_higher_flow(self):
        for rate in (500,2000):
            lua=self._fmf_runtime();lua.globals().test_rate=rate
            lua.execute("""
             local es={};for x=0,500 do es[#es+1]={entity_number=#es+1,name='pipe',position={x=x+.5,y=.5}}end
             local ps={{x=0,y=0,dir=4,kind='output',fluid='water',rate=test_rate},{x=500,y=0,dir=12,kind='input',fluid='water',rate=test_rate}}
             local result,id,status=require('fmf').promote(es,ps,502,{},catalog)
             assert((test_rate==500 and status.pumps==1 and status.bridges==0)or(test_rate==2000 and status.bridges==1))
             assert(#require('fluid_graph').check(result,ps)==0)
            """)

    def test_fmf_rejects_unresolved_extent_and_keeps_separate_small_networks(self):
        lua=self._fmf_runtime()
        lua.execute("""
         local es={};for x=0,500 do es[#es+1]={entity_number=#es+1,name='pipe',position={x=x+.5,y=.5}}end
         local ps={{x=0,y=0,dir=4,kind='output',fluid='water',rate=4000},{x=500,y=0,dir=12,kind='input',fluid='water',rate=4000}}
         local result,id,status=require('fmf').promote(es,ps,502,{},catalog)
         assert(status.skipped.extent==1 and status.bridges==0 and status.pumps==0)
         es={};for _,start in ipairs({0,500})do for x=start,start+20 do es[#es+1]={entity_number=#es+1,name='pipe',position={x=x+.5,y=.5}}end end
         result,id,status=require('fmf').promote(es,{},43,{},catalog)
         assert(not status.skipped.extent and status.bridges==0 and status.pumps==0 and #result==#es)
        """)

    def test_fmf_internal_branch_uses_native_junctions_in_every_rotation(self):
        lua=self._fmf_runtime()
        lua.execute("""
         local source={{name='duct',position={x=0,y=0},direction=8},{name='duct-small',position={x=0,y=1.5},direction=8},
          {name='duct-exhaust',position={x=0,y=3},direction=8},{name='duct-intake',position={x=0,y=6},direction=8},
          {name='duct-long',position={x=0,y=9},direction=8},{name='pipe',position={x=.5,y=4.5}},
          {name='pipe',position={x=1.5,y=4.5}},{name='pipe',position={x=2.5,y=4.5}},
          {name='duct-intake',position={x=3,y=6},direction=8},{name='duct-long',position={x=3,y=9},direction=8}}
         local work=require('generation_work');local orientation=require('orientation')
         for turn=0,3 do local es=work.copy(source);for i,e in ipairs(es)do e.entity_number=i;orientation.entity(e,turn)end
          local result,id,status=require('fmf_topology').coalesce(es,{},11,catalog)
          assert(status.junctions==1 and status.transitions_removed==3)
          local junctions=0
          for _,e in ipairs(result)do
           assert(e.name~='pipe'and e.name~='duct-intake'and e.name~='duct-exhaust','Internal FMF branch must stay in the duct network')
           if e.name=='duct-t-junction'then junctions=junctions+1 end
          end
          assert(junctions==1 and #require('fluid_graph').check(result,{})==0)
         end
        """)

    def test_bridge_poles_cannot_overlap_uncommitted_ancestor_poles(self):
        from lupa.lua52 import LuaRuntime
        source=(release.ROOT / "power.lua").read_text(encoding="utf8")
        start=source.index("     local function offer(x,y)")
        end=source.index("     local dx,dy=b.tx-n.x",start)
        LuaRuntime().execute("""
          local function key(x,y)return x..','..y end
          local p={w=2,h=2,wire=18}
          local n={x=0,y=0,cost=0}
          local b={tx=15,ty=0,cost={},parents={['0,0']={x=-3,y=-3}},heap={}}
          local s={xmin=-30,xmax=30,ymin=-30,ymax=30}
          local function free()return true end
          local accepted={}
          local function push(_,value)accepted[#accepted+1]=value end
        """+source[start:end]+"""
          offer(1,0)   -- overlaps the current, not-yet-built 2x2 pole
          offer(-3,-2) -- overlaps another pole in the candidate bridge
          offer(2,0)   -- touching footprints are allowed
          assert(#accepted==1 and accepted[1].x==2)
        """)

    def test_layout_point_buckets_preserve_exact_overlap_counts(self):
        import random
        from lupa.lua52 import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        source = (release.ROOT / "layout.lua").read_text(encoding="utf8")
        helpers = lua.execute(source.rsplit("return M", 1)[0] + "return {bucket=bucket, count=point_count}")
        rng = random.Random(133)
        points = [(rng.randrange(-100, 101) + .5, rng.randrange(-100, 101) + .5) for _ in range(2000)]
        points += points[:100]  # Repeated approach points still count separately.
        index = lua.table()
        for x, y in points:
            cell = helpers.bucket(index, x // 8, y // 8)
            cell[len(cell) + 1] = lua.table_from({"x": x, "y": y})
        for _ in range(300):
            x, y = rng.randrange(-120, 120), rng.randrange(-120, 120)
            w, h = rng.randrange(1, 80), rng.randrange(1, 80)
            expected = sum(x <= px < x + w and y <= py < y + h for px, py in points)
            self.assertEqual(helpers.count(index, lua.table_from({"x": x, "y": y, "w": w, "h": h})), expected)

    def test_completed_prefix_replay_is_bounded_and_mutable_results_stay_isolated(self):
        from lupa.lua52 import LuaRuntime
        lua = LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        ticks = lua.execute(r"""

local work=require('generation_work')
local data={values={}};for i=1,500 do data.values[i]=i end
work.register('test-result',function(args) return true,work.copy(args.data) end)
local cache={}
for tick=1,64 do
 work.begin(cache,64)
 local ok,value=pcall(function()
  work.resume_pending()
  return work.cached('parent',function()
   local values={}
   for i=1,8 do
    local value=work.operation('test-result',nil,{data=data})
    assert(value.values[1]==1,'mutable result leaked into cached snapshot')
    value.values[1]=-i;values[i]=value
   end
   return values
  end,true)
 end)
 work.finish()
 if ok then for i,v in ipairs(value) do assert(v.values[1]==-i) end;return tick end
 assert(work.is_pending(value),tostring(value))
 if tick%10==0 then cache=work.copy(cache) end
end
return false

""")
        self.assertIsNot(ticks,False,"Completed prefix replay repeated restoration instead of advancing")
        self.assertLessEqual(ticks,64)

    def test_pipe_interval_index_matches_exhaustive_overlap_checks(self):
        from lupa.lua52 import LuaRuntime
        import random
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        intervals=lua.eval("require('pipe_intervals')")
        rng=random.Random(124)
        tunnels=[]
        for _ in range(300):
            x,y=rng.randrange(-20,21),rng.randrange(-20,21)
            dx,dy=rng.randrange(-10,11),0
            if rng.randrange(2): dx,dy=dy,dx
            tunnels.append(dict(x=x,y=y,xx=x+dx,yy=y+dy))
        index=intervals.build(lua.table_from(tunnels,recursive=True))
        for _ in range(1000):
            x,y=rng.randrange(-30,31),rng.randrange(-30,31)
            dx,dy=rng.randrange(-15,16),0
            if rng.randrange(2):dx,dy=dy,dx
            xx,yy=x+dx,y+dy
            expected=not any((x==xx and t['x']==t['xx'] and x==t['x'] and max(min(y,yy),min(t['y'],t['yy']))<=min(max(y,yy),max(t['y'],t['yy']))) or
                (y==yy and t['y']==t['yy'] and y==t['y'] and max(min(x,xx),min(t['x'],t['xx']))<=min(max(x,xx),max(t['x'],t['xx']))) for t in tunnels)
            self.assertEqual(intervals.clear(index,x,y,xx,yy),expected)

    def test_long_handed_capacity_is_positive_without_joining_one_tile_catalog(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        rate=lua.execute("""
         prototypes={entity={belt={belt_speed=.03125},arm={type='inserter',
          inserter_pickup_position={x=0,y=-2},inserter_drop_position={x=0,y=2.2},
          get_inserter_rotation_speed=function()return .02 end,
          get_inserter_extension_speed=function()return .0457 end}},item={iron={stack_size=100}}}
         return require('transfer').rate('arm',{},'belt',{'iron'},'input')
        """)
        self.assertGreater(rate,0)
        self.assertLessEqual(rate,1.2)

    def test_section_transitions_use_remaining_budget_without_idle_ticks(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        ticks,total=lua.execute("""
         local work=require('generation_work');local cache={}
         for tick=1,50 do
          work.begin(cache,18000)
          local ok,value=pcall(function()
           work.resume_pending()
           local sum=0
           for i=1,100 do work.section_boundary();sum=sum+i end
           return sum
          end)
          work.finish()
          if ok then return tick,value end
          assert(work.is_pending(value),tostring(value))
          cache=work.copy(cache)
         end
         error('Section transitions did not complete within the tick budget')
        """)
        self.assertEqual(total,5050)
        self.assertLessEqual(ticks,8)

    def test_fast_belt_retry_requires_a_transport_upgrade(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={yellow={belt_speed=.03125},red={belt_speed=.0625}}}
         local capacity=require('capacity')
         local choice={input='yellow',output='red',fastest='red'}
         local issues={'Disconnected fluid network: water',rate_limits={}}
         assert(not capacity.retry_belts(choice,issues))
         issues.rate_limits[1]='input transfer deficit'
         assert(capacity.retry_belts(choice,issues))
         issues.rate_limits={};choice.output='yellow'
         assert(capacity.retry_belts(choice,issues))
         choice.input='red';choice.output='red'
         assert(not capacity.retry_belts(choice,issues))
         choice.belts={'yellow','red'};issues.belt_failures=1
         assert(capacity.retry_belts(choice,issues),'A local slow branch may need a longer underground tier')
         choice.belts={'red'};assert(not capacity.retry_belts(choice,issues),'Do not repeat a fastest-only pass')
        """)

    def test_foreign_underground_pipe_blocks_only_its_surface_opening(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        away,facing,ordinary=lua.execute("""
         local work=require('generation_work');local handlers={};local register=work.register
         work.register=function(label,fn)handlers[label]=fn;register(label,fn)end
         require('fluids')
         local args={p={x=0,y=0,dir=4,group='water'},targets={['2,0']=true},occupied={},
          network={['1,1']={group='oil',dir=8}},reserved={['1,1']='oil'},tunnels={},external_access={},
          xmin=0,xmax=2,ymin=0,ymax=0,maxdist=0}
         local function length()
          local done,path=handlers['fluid-search'](args,{})
          assert(done and path);return #path
         end
         local away=length()
         args.network['1,1'].dir=0;local facing=length()
         args.network['1,1'].dir=nil;local ordinary=length()
         return away,facing,ordinary
        """)
        self.assertEqual(away,2)
        self.assertGreater(facing,2)
        self.assertGreater(ordinary,2)

    def test_fluid_first_candidate_uses_recipe_data_before_placement(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local search=require('layout_search')
         local options={{gap=0,arrays={pack=true}},{gap=2,dense=true}}
         local blocks={{recipe_node={ingredients={{type='fluid',name='water'},{type='item',name='coal'}}}}}
         local result=search.fluid_first(options,blocks,'normal')
         assert(#result==4 and result[1].fluids_first and result[1].gap==2)
         assert(result[2].fluids_first and result[2].gap==4)
         assert(result[3]==options[1] and result[4]==options[2])
         assert(not options[1].fluids_first)
         assert(search.fluid_first(options,blocks,'thorough')==options)
         local containers=search.fluid_first(options,blocks,'normal','containers')
         assert(containers[1].gap==2 and containers[2].gap==6)
         assert(search.fluid_first(options,{},'normal')==options)
         local pure=search.fluid_first(options,{{recipe_node={ingredients={{type='fluid',name='water'}}}}},'normal')
         assert(pure[1].fluid_compact and pure[1].gap==0 and pure[1].align_ports and pure[1].flow_aware)
         assert(pure[2].gap==2 and not pure[2].fluid_compact,'Keep the proven clearance fallback')
        """)

    def test_underground_route_can_cross_a_foreign_surface_pipe(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local work=require('generation_work');local handlers={};local register=work.register
         work.register=function(label,fn)handlers[label]=fn;register(label,fn)end
         require('fluids')
         local args={p={x=0,y=0,dir=4,group='water'},targets={['4,0']=true},occupied={},
          network={['2,0']={group='oil'}},reserved={['2,0']='oil'},tunnels={},external_access={},
          xmin=0,xmax=4,ymin=0,ymax=0,maxdist=2}
         local done,path=handlers['fluid-search'](args,{})
         assert(done and path and #path==1)
         assert(path[1].ax==1 and path[1].bx==3 and path[1].dir==4)
        """)

    def test_blocked_belt_target_rejects_before_directional_search(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        plan,reason=lua.execute("""
         local routing=require('routing')
         return routing.plan{sx=0,sy=0,tx=5,ty=5,start_dir=4,final_dir=4,target_free=true,max_distance=0,
          occupied=function(x,y)if (x==4 and y==5) or (x==5 and (y==4 or y==6)) then return 'machine' end end,
          cell=function()end,margin=10}
        """)
        self.assertIsNone(plan)
        self.assertEqual(reason,'blocked-target-approach')

    def test_merged_outlet_keeps_surface_belt_before_tunnel(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
         local routing=require('routing')
         local c={occupied={['2,0']='machine'},endpoint_reservations={},reserved_taps={},
          cell_kind={['0,0']='belt',['0,1']='belt',['-1,0']='belt'},cell_dir={['0,0']=4,['0,1']=0,['-1,0']=4},
          block_cells={['0,0']=1,['0,1']=1,['-1,0']=1},machine_cells={},port_access={},source_owner=1,target_owner=2}
         local args={sx=0,sy=0,tx=6,ty=0,start_dir=4,final_dir=4,target_free=true,start_tunnel=true,
          max_distance=6,context=c,min_y=0,max_y=0,min_x=0,max_x=6,margin=0,avoid_empty_tunnels=true}
         local plan=assert(routing.plan(args),'Keep the merged outlet and start the tunnel one tile later')
         assert(plan[1].x==0 and plan[1].kind=='belt')
         local input;for _,p in ipairs(plan)do if p.kind=='ug_in'then input=p end end
         assert(input and input.x==1,'A side-fed outlet must not become an underground entrance')
         c.occupied['1,0']='machine'
         assert(not routing.plan(args),'Reject a boxed-in merge instead of discarding its side-fed lane')
        """)

    def test_own_block_tunnel_does_not_allow_foreign_transit(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local routing=require('routing')
         local c={occupied={['2,0']='machine',['3,0']='machine'},endpoint_reservations={},
          reserved_taps={},cell_kind={},cell_dir={},block_cells={},machine_cells={},port_access={},
          source_owner=1,target_owner=2}
         for x=0,4 do c.block_cells[x..',0']=1 end
         c.machine_cells['2,0']=true;c.machine_cells['3,0']=true
         local args={sx=0,sy=0,tx=6,ty=0,start_dir=4,final_dir=4,target_free=true,
          start_tunnel=true,max_distance=5,context=c,min_y=0,max_y=0,min_x=0,max_x=6,
          margin=0,avoid_empty_tunnels=true}
         local plan=assert(routing.plan(args),'Own ingredient/output tunnel must remain legal')
         local tunnels=0;for _,p in ipairs(plan) do if p.kind=='ug_in' then tunnels=tunnels+1 end end
         assert(tunnels==1)
         c.block_cells['2,0']=3;c.block_cells['3,0']=3
         assert(not routing.plan(args),'Foreign production block must not become a transit corridor')
        """)

    def test_existing_underground_belts_keep_their_own_tier(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local routing=require('routing')
         local c={occupied={['2,0']='belt',['4,0']='belt'},endpoint_reservations={},reserved_taps={},
          cell_kind={['2,0']='ug_in',['4,0']='ug_out'},cell_dir={['2,0']=4,['4,0']=4},
          ug_name='red',ug_names={['2,0']='yellow',['4,0']='yellow'}}
         local plan=assert(routing.plan{sx=0,sy=0,tx=7,ty=0,start_dir=4,final_dir=4,
          target_free=true,max_distance=5,ug_name='red',context=c,min_y=0,max_y=0,
          min_x=0,max_x=7,margin=0,avoid_empty_tunnels=true})
         local paired=false
         for i,p in ipairs(plan) do
          if p.kind=='ug_in' and p.x==1 and plan[i+1].x==6 then paired=true end
         end
         assert(paired,'Different underground tiers may cross without stealing a pair')
        """)

    def test_container_exports_preserve_terminal_slot_identity(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={tile_width=1,tile_height=1}}}
         package.loaded.capacity={belt=function()return 15 end}
         package.loaded.container_distribution={
          context=function()return {capacity=15}end,
          select=function()return {w=3,h=3}end,
          emit=function(es,id,c,s,ni,no,x,y,name)
           local inputs,outputs={},{}
           for i=1,ni do inputs[i]={x=x,y=y+i,direction=4};outputs[i]={x=x+4,y=y+i,direction=4}end
           return inputs,outputs,9,id
          end}
         local outputs,consumers=require('output_flows').plan(
          {{name='belt',position={x=.5,y=.5}}},{{name='iron-plate',type='item',rate=20}},
          {belt_out='belt',distribution_mode='containers',input_side=12,output_side=4},1,{})
         assert(#outputs==2 and #consumers==2)
         for i,p in ipairs(outputs) do assert(p.export_slot==i and consumers[i].export==p)end
        """)

    def test_internal_container_pools_all_producers_and_consumers(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={tile_width=1,tile_height=1,type='transport-belt',belt_speed=.03125},
          split={tile_width=2,tile_height=1,type='splitter',belt_speed=.03125},
          loader={tile_width=1,tile_height=1,type='loader-1x1',filter_count=0},
          box={tile_width=3,tile_height=3,type='container'}}}
         local hubs=require('container_distribution')
         hubs.context=function()return {loader='loader',containers={{name='box',w=3,h=3,slots=48}},selected='auto'}end
         local es,bs={},{}
         for i=1,5 do
          es[i]={entity_number=i,name='belt',position={x=.5,y=i*10+.5},direction=4}
          bs[i]={entity_first=i,entity_last=i,offset_y=i*10,height=1,width=1,
           recipe_node={name='recipe'..i,base_time=1,ingredients={},products={}}}
          if i<=2 then
           bs[i].recipe_node.products={{name='iron',type='item',count=6}}
           bs[i].output_ports={{x=0,y=i*10,direction=4}}
          else
           bs[i].recipe_node.ingredients={{name='iron',type='item',count=3}}
           bs[i].inputs={{x=0,y=i*10,direction=4,ingredient='iron'}}
          end
         end
         local id,n=require('junction_plan').apply(es,bs,{belt_in='belt',belt_out='belt',distribution_mode='containers'},6,
          {{name='iron',type='item',rate=3}},{splitters={}})
         assert(n==1 and #bs==6)
         local pool=bs[6];assert(#pool.inputs==2 and #pool.output_ports==4)
         local boxes,loaders=0,0
         for _,e in ipairs(es)do
          if e.name=='box'then boxes=boxes+1;assert(e.bar==nil,'A distribution pool must retain its inventory capacity')end
          if e.name=='loader'then loaders=loaders+1 end
          assert(not e.output_priority and not e.input_priority)
         end
         assert(boxes==1 and loaders==6)
         for i=1,2 do assert(bs[i].output_ports[1].flow_edge==pool.inputs[i].flow_edge)end
         for i=3,5 do assert(bs[i].inputs[1].flow_edge==pool.output_ports[i-2].flow_edge)end
         assert(pool.output_ports[4].graph_terminal and pool.output_ports[4].terminal_slot==1)
         local share=0;for _,p in ipairs(pool.output_ports)do share=share+p.share end;assert(math.abs(share-1)<1e-9)
         local direct_es={{entity_number=1,name='belt',position={x=.5,y=.5},direction=4},
          {entity_number=2,name='belt',position={x=4.5,y=.5},direction=4}}
         local direct_bs={
          {entity_first=1,entity_last=1,recipe_node={base_time=1,products={{name='iron',count=6}},ingredients={}},output_ports={{x=0,y=0,direction=4}}},
          {entity_first=2,entity_last=2,recipe_node={base_time=1,products={},ingredients={{name='iron',count=6}}},inputs={{x=4,y=0,direction=4,ingredient='iron'}}}}
         require('junction_plan').apply(direct_es,direct_bs,{belt_in='belt',belt_out='belt',distribution_mode='containers'},3,{}, {splitters={'split'}})
         assert(#direct_bs==2 and #direct_es==2,'A single source/consumer needs no distributor inventory')

        """)

    def test_container_inlets_face_the_actual_producer_after_placement(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={type='transport-belt',tile_width=1,tile_height=1},
          loader={type='loader-1x1',tile_width=1,tile_height=1},
          box={type='container',tile_width=2,tile_height=2}}}
         local es={{entity_number=1,name='box',position={x=1,y=1}},
          {entity_number=2,name='belt',position={x=4.5,y=.5},direction=12},
          {entity_number=3,name='belt',position={x=3.5,y=.5},direction=12},
          {entity_number=4,name='loader',position={x=2.5,y=.5},direction=12,type='input'}}
         local inlet={x=4,y=0,direction=12,flow_edge=1,ingredient='sulfur'}
         local bs={{output_ports={{x=0,y=-10,direction=8,flow_edge=1}}},
          {pool_container=true,entity_first=1,entity_last=4,inputs={inlet}}}
         assert(require('container_distribution').approach(es,bs)==1)
         assert(inlet.x==0 and inlet.y==-3 and inlet.direction==8)
         assert(es[4].position.x==.5 and es[4].position.y==-.5 and es[4].direction==8)
         assert(inlet.flow_edge==1 and inlet.ingredient=='sulfur')
         assert(require('container_distribution').approach(es,bs)==0,'Refitting must be stable')
         -- An occupied top approach must retain a free side instead.
         es[#es+1]={entity_number=5,name='box',position={x=1,y=-2}}
         inlet.x,inlet.y,inlet.direction=4,0,12
         for n=2,4 do es[n].position={x=6.5-n,y=.5};es[n].direction=12 end
         require('container_distribution').approach(es,bs)
         assert(inlet.direction~=8,'Blocked top approach selected')
        """)

    def test_container_outlet_avoids_a_foreign_block_turning_trap(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={type='transport-belt',tile_width=1,tile_height=1},
          loader={type='loader-1x1',tile_width=1,tile_height=1,filter_count=0},box={type='container',tile_width=2,tile_height=2}}}
         local module=require('container_distribution');local es={}
         local context={loader='loader',containers={{name='box',w=2,h=2}},selected='auto'}
         local _,outputs=module.emit(es,1,context,{belt_in='belt'},1,1,4,-2,'iron')
         local outlet=outputs[1];outlet.flow_edge=9;outlet.rate=.0125
         local primary={x=outlet.x,y=outlet.y,direction=outlet.direction,flow_edge=9}
         local last=#es;es[#es+1]={name='box',position={x=8,y=1}}
         local bs={{pool_container=true,entity_first=1,entity_last=last,inputs={},output_ports={outlet},product_out=primary},
          {entity_first=last+1,entity_last=last+1,inputs={{x=20,y=0,direction=4,flow_edge=9}}}}
         assert(module.approach(es,bs)==1)
         assert(outlet.direction~=4,'Do not aim a pool outlet into a nearby foreign production block')
         assert(primary.x==outlet.x and primary.y==outlet.y and primary.direction==outlet.direction)
         assert(outlet.flow_edge==9 and outlet.rate==.0125)
         assert(#es==last+1,'Refitting must not add transport')
         assert(module.approach(es,bs)==0,'Outlet refitting must be stable')
        """)

    def test_fractional_machine_transfer_uses_active_crafting_rate(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={type='transport-belt',tile_width=1,tile_height=1},
          slow={type='inserter',tile_width=1,tile_height=1,inserter_pickup_position={x=0,y=-1},inserter_drop_position={x=0,y=1.2}},
          fast={type='inserter',tile_width=1,tile_height=1,inserter_pickup_position={x=0,y=-1},inserter_drop_position={x=0,y=1.2}},
          machine={type='assembling-machine',tile_width=1,tile_height=1}}}
         local transfer=require('transfer')
         transfer.rate=function(n)return n=='slow' and 1.42857 or 3.52941 end
         local function choose(factor)
          local es={{entity_number=1,name='belt',position={x=.5,y=-.5},direction=4},
           {entity_number=2,name='slow',position={x=.5,y=.5},direction=0},
           {entity_number=3,name='machine',position={x=.5,y=1.5},recipe='processed-fuel'}}
          local _,limits=transfer.apply(es,1,{inputs={{x=0,y=-1,ingredient='coal'}}},
           {name='processed-fuel',base_time=1,physical_capacity_factor=factor,
            ingredients={{type='item',name='coal',count=1.2400977272727283}},products={}},
           {transfer_mode='auto',belt_in='belt',belt_out='belt'},4,
           {available={slow=true,fast=true},inserters={'slow','fast'},loaders={},splitters={}}, {},{},function()end)
          assert(#limits==0);return es[2].name
         end
         assert(choose(100)=='fast','Unreachable burst headroom must not report a deficit when planned throughput fits')
         assert(choose(1)=='slow')
         assert(choose(1/.545643)=='fast','A fractionally used machine must not be starved while crafting')
         local es={{entity_number=1,name='belt',position={x=.5,y=-.5},direction=4},
          {entity_number=2,name='fast',position={x=.5,y=.5},direction=0},
          {entity_number=3,name='machine',position={x=.5,y=1.5},recipe='processed-fuel'}}
         local _,limits=transfer.apply(es,1,{inputs={{x=0,y=-1,ingredient='coal'}}},
          {name='processed-fuel',base_time=1,ingredients={{type='item',name='coal',count=4}},products={}},
          {transfer_mode='auto',belt_in='belt',belt_out='belt'},4,
          {available={slow=true,fast=true},inserters={'slow','fast'},loaders={},splitters={}}, {},{},function()end)
         assert(#limits==1 and limits[1].required==4,'A real planned deficit must still fail')
        """)

    def test_recipe_less_water_producer_has_a_routed_output_port(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={recipe={},entity={pump={type='offshore-pump',fluidbox_prototypes={{index=1,
          production_type='output',pipe_connections={{connection_type='normal',direction=0,
           positions={{x=0,y=-1}}}}}}}}}
         local ports,issues=require('fluids').ports({{entity_number=1,name='pump',position={x=.5,y=.5}}},
          {{entity_first=1,entity_last=1,machine_ids={},recipe_node={base_time=1,ingredients={},
            products={{name='water',type='fluid',count=300}}}}})
         assert(#issues==0 and #ports==1)
         assert(ports[1].fluid=='water' and ports[1].kind=='output' and ports[1].rate==300)
         assert(ports[1].x==0 and ports[1].y==-2)
        """)

    def test_parallel_fluid_port_cannot_be_trapped_under_another_fluid_tunnel(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={block={tile_width=1,tile_height=1},pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local es={{entity_number=1,name='block',position={x=5.5,y=.5},direction=0}}
         local _,fail=require('fluids').route(es,
          {{x=0,y=0,dir=4,fluid='heavy-oil'},{x=4,y=0,dir=12,fluid='sulfuric-acid'}},
          2,{pipe='pipe'},function()end)
         assert(fail==0)
         for _,e in ipairs(es)do
          assert(not (e.name=='ug' and e.position.x==.5 and e.position.y==.5),
           'The early oil escape must not tunnel through the later acid port')
         end
        """)

    def test_direct_templates_obey_manual_inserter_policy(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={blue={},green={},loader={}}}
         local transfer=require('transfer');local rates={blue=2,green=8,loader=15}
         transfer.rate=function(name)return rates[name]end
         local catalog={inserters={'blue','green'},loaders={'loader'},available={blue=true,green=true,loader=true}}
         local function choose(mode,need)return transfer.single_device({transfer_mode=mode},catalog,{},'belt',{},'input','blue',need)end
         assert(choose('multiple',1)=='blue')
         assert(choose('multiple',4)==nil,'Do not silently replace a manually restricted inserter with a loader')
         assert(choose('faster',4)=='green')
         local name,is_loader=choose('loaders',4);assert(name=='loader' and is_loader)
        """)

    def test_blacklist_filters_without_changing_other_players_and_rejects_conflicts(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={blue={localised_name='Blue arm',type='inserter'},green={localised_name='Green arm',type='inserter'},
          machine={localised_name='Machine',type='assembling-machine'}}}
         local work=require('generation_work')
         work.operation=function()return {blue_item='blue',green_item='green'}end
         local equipment=require('equipment');local blocked={blue=true}
         local filtered=equipment.items({},blocked)
         assert(not filtered.blue_item and filtered.green_item=='green')
         assert(equipment.items({}).blue_item=='blue','Do not mutate a shared catalog or another player')
         local list=require('entity_blacklist')
         local s={entity_blacklist=blocked,transfer_mode='multiple',inserter_in='blue'}
         assert(list.check(s)[1]=='bfh.blacklist-conflict')
         s.transfer_mode='auto';assert(not list.check(s),'An inactive manual choice is not an automatic-mode conflict')
         local ok,err=pcall(list.validate_entities,{{name='blue'}},s)
         assert(not ok and err[1]=='bfh.blacklist-generated')
         s.entity_blacklist.machine=true
         assert(list.check(s,{{factory={name='machine'}}})[1]=='bfh.blacklist-plan')
        """)

    def test_output_corner_accepts_both_own_header_feeds_but_not_a_foreign_belt(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local context={occupied={['0,0']='belt',['0,-1']='belt',['1,0']='belt'},
          cell_dir={['0,0']=8,['0,-1']=8,['1,0']=12},cell_kind={['0,0']='belt',['0,-1']='belt',['1,0']='belt'},
          block_cells={['0,0']=1,['0,-1']=1,['1,0']=1},source_owner=1,target_owner=2,
          endpoint_reservations={},reserved_taps={},source_key='0,0',target_key='0,4'}
         local options={sx=0,sy=0,tx=0,ty=4,start_dir=8,final_dir=8,target_free=true,max_distance=0,context=context}
         local plan,reason=require('routing').plan(options)
         assert(plan,reason)
         context.block_cells['1,0']=3
         local foreign,why=require('routing').plan(options)
         assert(not foreign and why=='blocked-source','Do not permit a foreign T connection')
        """)

    def test_routing_budget_accounts_for_added_pool_connections(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local search=require('layout_search');local b={{inputs={}}}
         assert(search.route_budget(b,'normal')==240000)
         for i=1,60 do b[1].inputs[i]={flow_edge=i}end
         assert(search.route_budget(b,'normal')==360000)
         for i=61,200 do b[1].inputs[i]={flow_edge=i}end
         assert(search.route_budget(b,'normal')==720000 and search.route_budget(b,'thorough')==nil)
        """)

    def test_layout_reserves_local_fluid_fanout_before_packing(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local blocks={{layout_left=0,layout_top=0,layout_width=5,layout_height=5},
          {layout_left=10,layout_top=0,layout_width=3,layout_height=3}}
         require('fluids').layout_clearance(blocks,{{block=1,x=5,y=1,dir=4},{block=1,x=1,y=-1,dir=0}})
         assert(blocks[1].layout_left==0 and blocks[1].layout_top==-4)
         assert(blocks[1].layout_width==9 and blocks[1].layout_height==9)
         assert(blocks[2].layout_width==3 and blocks[2].layout_left==10,'Solid-only blocks keep their size')
        """)

    def test_fluid_planner_preserves_a_turnable_solid_inlet_approach(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={tile_width=1,tile_height=1,type='transport-belt'}}}
         local clear=require('fluids').solid_clearance(
          {{name='belt',position={x=5.5,y=.5},direction=4}},
          {{inputs={{x=5,y=0,direction=4}}}},{{x=2,y=0}})
         assert(clear['4,0'] and clear['3,0'])
         assert(not clear['2,0'],'A declared fluid mouth must remain available')
         local open=require('fluids').solid_clearance({},{{inputs={{x=5,y=0,direction=4}}}},{})
         assert(open['4,0'] and open['3,0'] and open['2,0'],'Reserve room to turn before a two-cell landing')
        """)

    def test_fluid_routes_preserve_pending_same_fluid_mouths_and_surface_landings(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
          prototypes={entity={block={tile_width=1,tile_height=1},pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
          package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
          local es={{entity_number=1,name='block',position={x=5.5,y=5.5}}}
          local _,fail=require('fluids').route(es,{{x=0,y=0,dir=0,fluid='water'},
            {x=10,y=0,dir=0,fluid='water'},{x=9,y=0,dir=0,fluid='water'}},2,{pipe='pipe'},function()end)
          assert(fail==0,'An earlier same-fluid route must preserve a pending machine opening')
          for _,e in ipairs(es)do if e.name=='ug'and e.position.x==9.5 and e.position.y==.5 then
            assert(e.direction==8,'Underground normal opening must face the machine')
          end end
          local path=require('generation_work').operation('fluid-search',nil,{p={x=0,y=0,dir=0,group='water'},
            targets={['8,0']=true},occupied={},network={['8,0']={group='water'}},reserved={},tunnels={},external_access={},
            required_surface={['1,0']=true},port_directions={},xmin=-5,xmax=15,ymin=-5,ymax=5,maxdist=10},true)
          assert(path)
          for _,edge in ipairs(path)do assert(not (edge.ax==1 and edge.ay==0)and not(edge.bx==1 and edge.by==0),
            'A reserved surface landing cannot be consumed by a later tunnel')end
        """)

    def test_special_space_exploration_inventories_are_not_distribution_containers(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
          local names={'se-delivery-cannon-chest','se-rocket-launch-pad','se-rocket-landing-pad','aai-storehouse','control-box'}
          package.loaded.equipment={items=function(_,excluded)
            local values={store_item='aai-storehouse',control_item='control-box'};local result={}
            for item,name in pairs(values)do if not(excluded and excluded[name])then result[item]=name end end;return result
          end,entities=function()return names end}
          defines={inventory={chest=1}};prototypes={entity={},item={store_item={subgroup={name='container-4'}},control_item={subgroup={name='production'}}}}
          for _,name in ipairs(names)do prototypes.entity[name]={tile_width=4,tile_height=4,get_inventory_size=function()return 100 end}end
          local storage=require('container_distribution');local catalog=storage.catalog({})
          assert(#catalog==1 and catalog[1].name=='aai-storehouse','Storage category, not inventory size, defines defaults')
          assert(#storage.catalog({},nil,nil,true)==2,'Special launch and delivery inventories are never selectable')
          local settings={container_name='aai-storehouse'};storage.set_allowed({},settings,'aai-storehouse',false)
          assert(settings.container_name=='auto'and #storage.catalog({},nil,settings.container_allowlist)==0)
          assert(#storage.catalog({})==1,'One player must not change another player defaults')
          storage.set_allowed({},settings,'control-box',true)
          catalog=storage.catalog({},nil,settings.container_allowlist)
          assert(#catalog==1 and catalog[1].name=='control-box','Unknown categories require explicit player selection')
          settings.container_allowlist['se-rocket-launch-pad']=true
          assert(#storage.catalog({},nil,settings.container_allowlist)==1)
        """)

    def test_many_producers_use_an_ordinary_collector_before_the_distributor(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        source=(release.ROOT/'junction_plan.lua').read_text(encoding='utf-8')
        pool=source[source.index('local function pool('):source.index('local function resource(')]
        lua.execute("local work=require('generation_work');local capacity=require('capacity');local containers=require('container_distribution');"+pool+"""
          prototypes={entity={belt={belt_speed=.0625},loader={filter_count=0},store={}}}
          local es,bs,sources,sinks={},{},{},{}
          for i=1,7 do
            local p={x=i,y=0,direction=8};bs[i]={entity_first=1,entity_last=0,inputs={},height=1,
              recipe_node={name='source',base_time=1,factory={count=1},products={{name='metal',type='item',count=85/7}}}}
            sources[i]={bi=i,port=p,rate=85/7}
          end
          for i=1,10 do
            local p={x=i,y=10,direction=8,ingredient='metal'}
            bs[7+i]={entity_first=1,entity_last=0,inputs={p},height=1,
              recipe_node={name='sink',base_time=1,factory={count=1},ingredients={{name='metal',type='item',count=8.5}},products={}}}
            sinks[i]={bi=7+i,port=p,rate=8.5}
          end
          local _,_,ok=pool(es,bs,'metal',sources,sinks,85,{belt_out='belt',container_context={loader='loader',
            selected='auto',containers={{name='store',w=4,h=4,slots=100}}}},1,0)
          assert(ok and #bs==19)
          assert(#bs[18].inputs==7 and #bs[18].output_ports==3)
          assert(#bs[19].inputs==3 and #bs[19].output_ports==10)
          local boxes=0;for _,e in ipairs(es)do if e.name=='store'then boxes=boxes+1 end end;assert(boxes==2)
          for i=8,17 do assert(math.abs(bs[i].inputs[1].graph_rate-8.5)<1e-8)end
          for _,p in ipairs(bs[18].output_ports)do assert(p.flow_edge and not p.graph_terminal)end
        """)

    def test_container_inlets_match_nearby_producers_without_undersizing_transport(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path="+json.dumps(release.ROOT.as_posix()+"/?.lua;")+"..package.path")
        lua.execute("""
          prototypes={entity={belt={type='transport-belt',tile_width=1,tile_height=1,belt_speed=.0625},
            yellow={type='transport-belt',tile_width=1,tile_height=1,belt_speed=.03125},
            loader={type='loader-1x1',tile_width=1,tile_height=1,belt_speed=.0625},
            box={type='container',tile_width=4,tile_height=4}}}
          local function check(limited)
            local es={{name='belt',position={x=.5,y=.5},direction=8},{name='belt',position={x=20.5,y=.5},direction=8},
              {name='box',position={x=10,y=10}}}
            for _,x in ipairs({9,10})do for y=5,7 do es[#es+1]={name=y==7 and 'loader'or(limited and x==9 and'yellow'or'belt'),position={x=x+.5,y=y+.5},direction=8}end end
            local a={x=9,y=5,direction=8,flow_edge=2,graph_rate=10,layout_rate=10,ingredient='metal'}
            local b={x=10,y=5,direction=8,flow_edge=1,graph_rate=20,layout_rate=20,ingredient='metal'}
            local blocks={{entity_first=1,entity_last=1,output_ports={{x=0,y=0,direction=8,flow_edge=1}}},
              {entity_first=2,entity_last=2,output_ports={{x=20,y=0,direction=8,flow_edge=2}}},
              {entity_first=3,entity_last=#es,pool_container=true,inputs={a,b},output_ports={}}}
            require('container_distribution').approach(es,blocks)
            if limited then assert(a.flow_edge==2 and a.graph_rate==10,'Never move a 20/s feed onto a 15/s inlet')
            else assert(a.flow_edge==1 and a.graph_rate==20 and b.flow_edge==2 and b.graph_rate==10,'Nearby sockets must follow nearby producers')end
          end
          check(false);check(true)
        """)

    def test_boxed_fluid_mouth_reserves_an_escape_before_other_networks(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={wall={tile_width=1,tile_height=1},pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local es={};local function wall(x,y)es[#es+1]={entity_number=#es+1,name='wall',position={x=x+.5,y=y+.5}}end
         for y=0,6 do wall(2,y);wall(4,y)end
         for _,y in ipairs({0,3,6})do wall(3,y)end
         for x=-8,-1 do wall(x,0);wall(x,2)end
         local ps={{x=-10,y=0,dir=4,fluid='gas',external=true},
          {x=0,y=2,dir=12,fluid='gas',external=true},
          {x=3,y=1,dir=12,fluid='acid',kind='input'},
          {x=3,y=4,dir=12,fluid='acid',kind='input'},
          {x=-12,y=4,dir=4,fluid='acid',external=true}}
         local logs={};local _,fail=require('fluids').route(es,ps,#es+1,{pipe='pipe',link_mode='direct'},function(v)logs[#logs+1]=v end)
         assert(fail==0,table.concat(logs,'; '))
        """)

    def test_free_fluid_mouth_connects_directly_without_a_forced_underground_detour(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local es={};local ps={{x=0,y=0,dir=0,fluid='water',kind='output'},
          {x=0,y=-1,dir=0,fluid='water',kind='input',external=true}}
         local _,fail=require('fluids').route(es,ps,1,{pipe='pipe',link_mode='direct'},function()end)
         assert(fail==0 and #es==2,'An adjacent open connection needs only two surface pipes')
         for _,e in ipairs(es)do assert(e.name=='pipe','Do not force an underground escape at an open mouth')end
        """)

    def test_fluid_strip_keeps_stages_touching_without_reserving_empty_aprons(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local blocks={
          {layout_left=0,layout_top=0,layout_width=3,layout_height=6,recipe_node={ingredients={{name='light'}},products={{name='gas'}}}},
          {layout_left=0,layout_top=0,layout_width=5,layout_height=5,recipe_node={ingredients={{name='crude'}},products={{name='heavy'}}}},
          {layout_left=0,layout_top=0,layout_width=3,layout_height=6,recipe_node={ingredients={{name='heavy'}},products={{name='light'}}}}}
         local shifts=require('layout').fluid_strip(blocks)
         assert(shifts[2].y==0 and shifts[3].y==5 and shifts[1].y==11)
         assert(shifts[2].x==0 and shifts[3].x==2 and shifts[1].x==2)
        """)

    def test_fluid_placement_affinities_use_real_ports_and_bounded_flow(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local function block(x,kind,rate)
          return {recipe_node={base_time=1,ingredients=kind=='input' and {{name='oil',count=rate}}or{},
           products=kind=='output' and {{name='oil',count=rate}}or{}},
           layout_fluid_ports={{x=x,y=0,kind=kind,fluid='oil',rate=rate}}}
         end
         local blocks={block(0,'output',30),block(10,'input',20),block(40,'input',20),block(50,'output',10)}
         local wires=require('flow_layout').fluid_wires(blocks)
         local supplied,received={},{}
         for _,w in ipairs(wires)do
          assert(w.source~=w.target and w.source_fluid==1 and w.target_fluid==1)
          supplied[w.source]=(supplied[w.source]or 0)+w.rate
          received[w.target]=(received[w.target]or 0)+w.rate
         end
         assert(#wires==3 and supplied[1]==30 and supplied[4]==10 and received[2]==20 and received[3]==20)
         assert(wires[1].source==1 and wires[1].target==2,'Prefer the nearby real fluid port')
         -- A hierarchy group exposes only its net demand, even though it retains internal ports.
         blocks[2].recipe_node.ingredients[1].count=5
         local net=0;for _,w in ipairs(require('flow_layout').fluid_wires(blocks))do if w.target==2 then net=net+w.rate end end
         assert(net==5,'Do not attract supply already consumed inside a compound')
        """)

    def test_adjacent_chemical_inputs_can_turn_after_the_underground_landing(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={plant={tile_width=3,tile_height=3},pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local es={{entity_number=1,name='plant',position={x=5.5,y=1.5},direction=12},
                   {entity_number=2,name='plant',position={x=5.5,y=4.5},direction=12}}
         local ports={{x=3,y=2,dir=12,fluid='water'}, {x=3,y=0,dir=12,fluid='light-oil'},
           {x=7,y=2,dir=4,fluid='petroleum-gas'}, {x=3,y=5,dir=12,fluid='water'},
           {x=3,y=3,dir=12,fluid='light-oil'}, {x=7,y=5,dir=4,fluid='petroleum-gas'},
           {x=-2,y=0,dir=4,fluid='light-oil',external=true},
           {x=-2,y=3,dir=4,fluid='water',external=true},
           {x=12,y=2,dir=4,fluid='petroleum-gas',external=true,terminal=true}}
         local _,fail=require('fluids').route(es,ports,3,{pipe='pipe',link_mode='direct',external_face_x=-2},function()end)
         assert(fail==0,'Both adjacent inputs must be routed; the landing may turn before the input boundary')
        """)

    def test_pipe_escape_does_not_commit_a_landing_in_a_sealed_pocket(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={rail={tile_width=13,tile_height=1},wall={tile_width=11,tile_height=1},
          pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local es={{entity_number=1,name='rail',position={x=9.5,y=-.5},direction=0},
          {entity_number=2,name='rail',position={x=9.5,y=1.5},direction=0},
          {entity_number=3,name='wall',position={x=10.5,y=.5},direction=0}}
         local _,fail=require('fluids').route(es,{{x=0,y=0,dir=4,fluid='water'}},4,{pipe='pipe'},function()end)
         assert(fail==0)
         for _,e in ipairs(es)do
          assert(not (e.name=='ug' and e.position.x==.5 and e.position.y==.5),
           'Leave the source available instead of committing its only exit into a two-cell pocket')
         end
        """)

    def test_fluid_route_around_large_block_bounds_search_work(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={block={tile_width=20,tile_height=20},pipe={tile_width=1,tile_height=1},ug={tile_width=1,tile_height=1}}}
         package.loaded.pipe_pair={resolve=function()return 'ug',10 end}
         local visits=0;local work=require('generation_work')
         work.route_visit=function()visits=visits+1;return true end
         local es={{entity_number=1,name='block',position={x=20,y=0},direction=0}}
         local _,fail=require('fluids').route(es,
          {{x=0,y=0,dir=4,fluid='water',external=true},{x=40,y=0,dir=12,fluid='water',external=true}},
          2,{pipe='pipe'},function()end)
         assert(fail==0 and #es>1)
         assert(visits<250,'A simple obstacle must not consume the search budget in remote detours')
        """)

    def test_full_auto_retries_capacity_rejection_before_reporting_it(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local c=require('capacity')
         assert(c.retry_error('auto_equipment',{'bfh.container-loader-slow','copper-ore'},false))
         assert(c.retry_error('auto_equipment',{'bfh.auto-transfer-unsupported'},false))
         assert(not c.retry_error('auto_equipment',{'bfh.container-loader-slow'},true),'The fastest retry must be bounded')
         assert(not c.retry_error('loaders',{'bfh.container-loader-slow'},false),'Respect explicit manual equipment')
         assert(not c.retry_error('auto_equipment',{'bfh.blacklist-plan'},false),'A blacklist conflict is not a capacity retry')
        """)

    def test_external_container_demand_is_per_inlet_not_per_recipe(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local plan=require('external_inputs')
         local a={ingredient='copper-ore',graph_rate=28};local b={ingredient='copper-ore',graph_rate=28};local c={ingredient='copper-ore',graph_rate=29}
         local block={recipe_node={base_time=1,ingredients={{name='copper-ore',count=85}}},inputs={a,b,c}}
         assert(plan.input_rate(block,a)==28 and plan.input_rate(block,c)==29,'Do not require85/s from each30/s loader')
         a.graph_rate=nil;b.graph_rate=nil;c.graph_rate=nil
         assert(math.abs(plan.input_rate(block,a)-85/3)<1e-8)
         a.graph_rate=25;b.array_supply_rate=30
         assert(plan.input_rate(block,c)==30,'Subtract known inlet shares before distributing the remainder')
        """)

    def test_pool_branch_belt_uses_its_flow_instead_of_an_unrelated_fast_tier(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={yellow={belt_speed=.03125},red={belt_speed=.0625}}}
         local m=require('container_distribution');local c={auto_belts={'yellow','red'}}
         assert(m.branch_belt(c,'red',12)=='yellow')
         assert(m.branch_belt(c,'red',20)=='red')
         assert(m.branch_belt(c,'red',8,.5)=='red','A half-lane feeder must carry the full requested lane flow')
         assert(m.branch_belt({},'red',12)=='red','Manual choices must remain explicit')
        """)

    def test_internal_pool_stock_bypass_is_thresholded_and_shared(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={type='transport-belt',tile_width=1,tile_height=1},
          loader={type='loader-1x1',tile_width=1,tile_height=1,filter_count=0},
          box={type='container',tile_width=3,tile_height=3},
          decider={type='decider-combinator',tile_width=1,tile_height=2}},item={['copper-plate']={stack_size=100}}}
         defines={wire_connector_id={circuit_red=1,combinator_input_red=2,combinator_output_green=3}}
         local es={};local ctx={loader='loader',controller='decider',internal=true,
          containers={{name='box',w=3,h=3,slots=48}},selected='auto'}
         local _,outs=require('container_distribution').emit(es,1,ctx,{belt_in='belt'},1,2,10,0,'copper-plate')
         assert(es[1].bar==nil,'Do not reduce a buffer inventory to a single slot')
         local control
         for _,e in ipairs(es)do if e.name=='decider'then control=e end end
         assert(control and outs[1].stock_controller_id==control.entity_number and outs[2].stock_controller_id==control.entity_number)
         local d=control.control_behavior.decider_conditions
         assert(d.conditions[1].first_signal.name=='copper-plate'and d.conditions[1].constant==500 and d.conditions[1].comparator=='>')
         assert(d.outputs[1].constant<0 and d.outputs[1].copy_count_from_input==false)
        """)

    def test_container_branch_buffers_bound_transit_without_filling_long_belts(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={belt={type='transport-belt',belt_speed=.03125}}}
         defines={wire_connector_id={circuit_red=1},control_behavior={transport_belt={content_read_mode={entire_belt_hold=2}}}}
         local es={{entity_number=1,name='belt',position={x=.5,y=.5}},
          {entity_number=2,name='belt',position={x=1.5,y=.5}}}
         local blocks={{output_ports={{flow_buffer={gate={x=0,y=0},reader={x=1,y=0},tiles=100,rate=.01,item='iron-plate'}}}}}
         local n=require('container_distribution').regulate(es,blocks,{belt_in='belt',belt_out='belt'})
         assert(n==1 and es[2].control_behavior.circuit_contents_read_mode==2)
         assert(es[1].control_behavior.circuit_condition.constant==25,
          'A full loader and closed gate must not lock an empty consumer branch')
         blocks[1].output_ports[1].flow_buffer.prefix_tiles=4
         game={forces={player={belt_stack_size_bonus=2}}}
         require('container_distribution').regulate(es,blocks,{belt_in='belt',belt_out='belt'})
         assert(es[1].control_behavior.circuit_condition.constant==169,
          'Upstream route and stacked belts require proportional headroom')
         blocks[1].output_ports[1].flow_buffer.delivery_first=1
         blocks[1].output_ports[1].flow_buffer.delivery_last=2
         require('container_distribution').regulate(es,blocks,{belt_in='belt',belt_out='belt'})
         assert(es[1].control_behavior.circuit_condition.constant==217,
          'Consumer delivery headers are included in the native whole-belt count')
         assert(es[1].wires[1][1]==1 and es[1].wires[1][3]==2)
        """)

    def test_silo_unloader_keeps_satellite_in_cargo(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         package.loaded.transfer={rate=function()return 100 end,
          single_device=function()return 'inserter',false end}
         prototypes={entity={silo={type='rocket-silo',tile_width=9,tile_height=9,fixed_recipe={name='rocket-part'}},
          inserter={filter_count=5}}}
         local r={name='satellite',base_time=1,ingredients={},products={{name='telemetry'..string.char(31)..'rare',count=.125}}}
         for i=1,5 do r.ingredients[i]={name='ingredient-'..i,count=.1}end
         local es={};local function build()
          return require('many_solid').build(r,{belt_in='belt',belt_out='belt'},'silo',1,0,0,1,es,
           {available={['long-handed-inserter']=true}},{},'ug','ug')
         end
         local _,_,meta=build();assert(meta.launch_products and not meta.product_out)
         local unloaders=0
         for _,e in ipairs(es)do
          if e.name=='silo'then assert(e.launch_to_orbit_automatically)end
          if e.use_filters then
           unloaders=unloaders+1
           assert(e.filters[1].name=='telemetry' and e.filters[1].quality=='rare')
           assert(e.filter_mode=='whitelist')
          end
         end
         assert(unloaders==0,'Launch products must be unloaded from a landing pad, never from the silo')
        """)

    def test_launch_products_share_one_named_pad_and_filtered_output(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         local waiting=false
         package.loaded.equipment={items=function(_,excluded)if waiting then error('WAIT')end;return excluded and excluded['cargo-landing-pad'] and {} or {pad='cargo-landing-pad'}end,
          entities=function(_,_,items)return items.pad and {'cargo-landing-pad'} or {}end}
         package.loaded.transfer={single_device=function()return 'inserter',false end}
         prototypes={entity={silo={type='rocket-silo'},['cargo-landing-pad']={tile_width=8,tile_height=8},
          inserter={filter_count=5},belt={belt_speed=.03125}}}
         game={forces={player={}},tick=10};script={active_mods={['space-exploration']='test'}}
         local function fixture()
          local es={{name='silo',entity_number=1},{name='silo',entity_number=2}};local bs={}
          for i=1,2 do bs[i]={launch_products=true,entity_first=i,entity_last=i,offset_y=i*10,height=9,
           products={'telemetry'},recipe_node={base_time=1,products={{name='telemetry',count=.125}}}}end
          return es,bs
         end
         local es,bs=fixture();waiting=true
         assert(not pcall(require('launch_products').apply,es,bs,{belt_out='belt'},3,{},{}))
         assert(#es==2 and bs[1].launch_products and #bs[1].recipe_node.products==1,
          'A yielded equipment lookup must not consume or mutate launch metadata')
         waiting=false
         require('launch_products').apply(es,bs,{belt_out='belt',launch_pad_name='dedicated'},3,{},{} )
         assert(#bs==3 and #bs[1].recipe_node.products==0 and #bs[2].recipe_node.products==0)
         assert(bs[3].recipe_node.products[1].count==.25 and bs[3].output_ports[1].share==1)
         assert(es[1].tags.landing_pad_name=='dedicated' and es[2].tags.landing_pad_name=='dedicated')
         local pads,filtered=0,0
         for _,e in ipairs(es)do
          if e.name=='cargo-landing-pad'then pads=pads+1;assert(e.tags.name=='dedicated')end
          if e.use_filters then filtered=filtered+1;assert(e.filters[1].name=='telemetry')end
         end
         assert(pads==1 and filtered==1)
         local multi_es,multi_bs=fixture()
         multi_bs[2].recipe_node.products[1].name='telemetry'..string.char(31)..'rare'
         require('launch_products').apply(multi_es,multi_bs,{belt_out='belt'},3,{},{} )
         local multi=multi_bs[3]
         for _,port in ipairs(multi.output_ports)do
          local named=multi.product_outs[port.product]
          assert(named~=port and named.x==port.x and named.y==port.y,
           'Rotation and translation traverse both port lists; aliases would move a shared port twice')
          named.x=named.x+1;assert(named.x~=port.x)
         end

         es,bs=fixture();local ok,reason=pcall(require('launch_products').apply,es,bs,
          {belt_out='belt',entity_blacklist={['cargo-landing-pad']=true}},3,{},{} )
         assert(not ok and reason[1]=='bfh.launch-no-pad','A forbidden landing pad must not be generated')
        """)

    def test_landing_pad_blueprint_preserves_forced_build_grid(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={pad={type='cargo-landing-pad',build_grid_size=2}}}
         local bp={get_blueprint_entities=function()return {{name='pad',position={x=3,y=-5}}}end}
         local origin=require('launch_products').align_blueprint(bp)
         assert(origin.x==1 and origin.y==1)
         assert(bp.blueprint_absolute_snapping and bp.blueprint_snap_to_grid.x==2)
         assert((3+origin.x)%2==0 and (-5+origin.y)%2==0,
          'The pad and its unloader must move together onto the native building grid')
        """)

    def test_corner_fluid_connection_uses_explicit_face_direction(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("prototypes={entity={chem={fluidbox_prototypes={{production_type='input',pipe_connections={{direction=0,positions={{x=-1,y=-1},{x=1,y=-1},{x=1,y=1},{x=-1,y=1}}}}}}}}}")
        source=(release.ROOT/'control.lua').read_text(encoding='utf8')
        start=source.index('local function get_fluid_connections(')
        end=source.index('\nend\n',start)+5
        get_connections=lua.execute(source[start:end]+'\nreturn get_fluid_connections')
        for direction in (0,4,8,12):
            self.assertEqual(get_connections('chem',3,3,direction)[1]['dir'],direction,
                             'A corner coordinate alone cannot identify the connection face')

    def test_forced_grid_is_applied_before_blueprint_serialisation(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={pad={type='cargo-landing-pad',build_grid_size=2},belt={type='transport-belt'}}}
         local launch=require('launch_products');local orientation=require('orientation')
         for turn=0,3 do
          local es={{name='pad',position={x=-113,y=86}},
           {name='belt',position={x=-108.5,y=82.5},drop_position={x=-107.5,y=82.5}}}
          for _,e in ipairs(es)do orientation.entity(e,turn)end
          local dx=es[2].position.x-es[1].position.x;local dy=es[2].position.y-es[1].position.y
          local port={x=math.floor(es[2].position.x),y=math.floor(es[2].position.y),direction=4}
          local inputs={port};local outputs={{x=port.x,y=port.y,sources={port}}}
          launch.align_entities(es,inputs,outputs)
          assert(es[1].position.x%2==0 and es[1].position.y%2==0,'Native pad snapping must not move the pad independently')
          assert(es[2].position.x-es[1].position.x==dx and es[2].position.y-es[1].position.y==dy)
          assert(port.x==math.floor(es[2].position.x) and outputs[1].x==port.x,'Shared port must move exactly once')
          local x,y=es[2].position.x,es[2].position.y;launch.align_entities(es,inputs,outputs)
          assert(es[2].position.x==x and es[2].position.y==y,'Alignment must be stable')
         end
        """)

    def test_fluid_grid_leaves_every_input_mouth_free_and_unloads_onto_belts(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         defines={direction={north=0,east=4,south=8,west=12}}
         local function connection(positions)return {connection_type='normal',direction=0,positions=positions}end
         prototypes={entity={chem={type='assembling-machine',tile_width=3,tile_height=3,fluidbox_prototypes={
          {index=1,production_type='input',pipe_connections={connection({{x=-1,y=-1},{x=1,y=-1},{x=1,y=1},{x=-1,y=1}})}},
          {index=2,production_type='input',pipe_connections={connection({{x=1,y=-1},{x=1,y=1},{x=-1,y=1},{x=-1,y=-1}})}}}},
          belt={type='transport-belt',tile_width=1,tile_height=1},arm={type='inserter',tile_width=1,tile_height=1}},
          recipe={sulfur={ingredients={{name='water',type='fluid'},{name='gas',type='fluid'}},products={{name='sulfur',type='item'}}}}}
         get_machine_name=function(r)return 'chem'end;get_entity_size=function()return 3,3 end
         get_machine_count=function(r)return r.factory.count end
         get_fluid_ingredients=function()return {'water','gas'}end;get_fluid_products=function()return {}end
         get_ingredient_names=function()return {}end;get_solid_products=function()return {'sulfur'}end
         to_pipe_underground=function()return 'ug'end
         add_entity_cell=function(es,id,name,x,y,w,h,d,extra,ox,oy)
          local e={entity_number=id,name=name,position={x=x+ox+w/2,y=y+oy+h/2},direction=d}
          for k,v in pairs(extra or {})do e[k]=v end;es[#es+1]=e;return id+1
         end
        """)
        source=(release.ROOT/'control.lua').read_text(encoding='utf8')
        def function_text(name):
            start=source.index('local function '+name+'(')
            return source[start:source.index('\nend\n',start)+5]
        build=lua.execute(function_text('get_fluid_connections')+'\n'+function_text('build_block_fluid_grid')+'\nreturn build_block_fluid_grid')
        lua.globals().build_grid=build
        lua.execute("""
         for _,mode in ipairs({'independent','direct'})do for _,count in ipairs({2,3,8,15})do
          local r={name='sulfur',base_time=1,factory={count=count},ingredients={{name='water',type='fluid',count=30*count},
           {name='gas',type='fluid',count=30*count}},products={{name='sulfur',type='item',count=2*count}}}
          local es={};local _,_,meta=build_grid(r,0,0,{belt_out='belt',inserter_out='arm',link_mode=mode},1,es,{})
          meta.entity_first=1;meta.entity_last=#es;meta.recipe_node=r
          local ports=require('fluids').ports(es,{meta});assert(#ports==count*2)
          local cells={}
          for _,e in ipairs(es)do local p=prototypes.entity[e.name];local x=math.floor(e.position.x-p.tile_width/2);local y=math.floor(e.position.y-p.tile_height/2)
           for xx=x,x+p.tile_width-1 do for yy=y,y+p.tile_height-1 do cells[xx..','..yy]=e.name end end
          end
          for _,p in ipairs(ports)do assert(not cells[p.x..','..p.y],'An output device blocks a fluid inlet')end
          local arms=0;for _,e in ipairs(es)do if e.name=='arm'then
           arms=arms+1;local dx=e.direction==12 and 1 or -1
           assert(cells[math.floor(e.position.x+dx)..','..math.floor(e.position.y)]=='belt','Unloader must drop onto its output belt')
          end end;assert(arms==count)
         end end
        """)

    def test_independent_banks_route_locally_before_packing_complete_footprints(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         prototypes={entity={machine={tile_width=1,tile_height=1},pipe={tile_width=1,tile_height=1}}}
         local fluid=require('fluids');local calls=0
         fluid.ports=function(es,bs)
          assert(#es==1 and #bs==1,'An independent bank must not see neighbours while routing')
          return {},{}
         end
         fluid.route=function(es,ports,id)
          calls=calls+1
          es[#es+1]={entity_number=id,name='pipe',position={x=es[1].position.x-2,y=.5}}
          return id+1,0
         end
         local es={{entity_number=1,name='machine',position={x=.5,y=.5}},
          {entity_number=2,name='machine',position={x=1.5,y=.5}}}
         local bs={}
         for i=1,2 do local port={x=i-1,y=0};bs[i]={entity_first=i,entity_last=i,offset_x=i-1,offset_y=0,width=1,height=1,
          product_out=port,output_ports={port},recipe_node={x=123}}end
         local id,fail,result=fluid.independent(es,bs,100,{},function()end,6)
         assert(calls==2 and fail==0 and id==102 and #result==4)
         assert(es[1].position.x==.5 and es[2].position.x==1.5,'Routing must not mutate the immutable template input')
         assert(bs[1].entity_first==1 and bs[1].entity_last==2 and bs[2].entity_first==3 and bs[2].entity_last==4)
         assert(result[4].position.x-result[1].position.x>=2,'Finished pipe footprints must be separated')
         assert(bs[1].product_out.x==math.floor(result[1].position.x),'Shared port metadata moved twice')
         assert(bs[2].product_out.x==math.floor(result[3].position.x))
         assert(bs[1].recipe_node.x==123,'Recipe values are not placement coordinates')
        """)

    def test_batched_input_loop_preserves_pickup_and_reserves_return_columns(self):
        from lupa.lua52 import LuaRuntime
        lua=LuaRuntime()
        lua.execute("package.path=" + json.dumps(release.ROOT.as_posix() + "/?.lua;") + "..package.path")
        lua.execute("""
         package.loaded.transfer={rate=function()return 1 end}
         local loops=require('input_loops')
         prototypes={entity={machine={tile_width=3,tile_height=3},belt={type='transport-belt'},arm={type='inserter'},['long-handed-inserter']={type='inserter',inserter_pickup_position={x=0,y=-2},inserter_drop_position={x=0,y=2.2}}}}
         local function fixture(width)
          width=width or 15
          local es={};local function add(name,x,y,d)es[#es+1]={name=name,entity_number=#es+1,position={x=x+.5,y=y+.5},direction=d}end
          for _,side in ipairs({{0,1,2,4},{width-1,width-2,width-3,12}})do
           add('belt',side[1],5,8);add('belt',side[1],26,side[4]);add('belt',side[2],26,side[4]);add('arm',side[3],26,(side[4]+8)%16)
          end
          return es,{offset_x=0,offset_y=0,width=width,height=28,ing_count=3,ingredients={'a','b','batch'},inputs={{x=6,y=2}},products={'science'}}
         end
         local r={ingredients={{name='a',count=1},{name='b',count=1},{name='batch',count=.125}},base_time=1,factory={name='machine'}}
         local opt={transfer_mode='auto',belt_in='belt',transport_quality='normal'}
         local catalog={available={['long-handed-inserter']=true}}
         local es,m=fixture();local id,n=loops.apply(es,1,m,r,14,opt,100,catalog,{}, {batch=true})
         assert(n==2 and id==144 and m.offset_x==-1 and m.width==17)
         assert(es[1].direction==8 and m.inputs[1].x==6,'Original feed positions must remain fixed')
         local long=0;local cells={}
         for _,e in ipairs(es)do local k=e.position.x..','..e.position.y;assert(not cells[k],'Loop introduced duplicate cells');cells[k]=e
          if e.name=='long-handed-inserter'then long=long+1;assert(e.position.y==26.5)end
         end
         assert(long==2 and not cells['1.5,26.5'] and not cells['13.5,26.5'])
         assert(cells['-0.5,5.5'].direction==4 and cells['15.5,5.5'].direction==12)
         local a,b=fixture(16);b.power_gap=1
         local function add(name,x,y,d)a[#a+1]={name=name,entity_number=#a+1,position={x=x+.5,y=y+.5},direction=d}end
         for row=0,6 do local y=6+row*3+(row%2==0 and 2 or 0);add('arm',9,y,4);add('belt',8,y,12)end
         local rr={ingredients=r.ingredients,products={{name='science',count=1}},base_time=1,factory=r.factory}
         local next_id,changed=loops.apply(a,1,b,rr,14,{transfer_mode='auto',belt_in='belt',belt_out='belt'},100,catalog,{}, {batch=true})
         assert(changed==2 and b.width==18)
         local outputs=0
         for _,e in ipairs(a)do
          assert(e.position.x~=8.5 or e.name~='belt','Temporary output bridges must leave the pole column free')
          if e.position.x==9.5 then assert(e.name=='long-handed-inserter' and e.direction==4);outputs=outputs+1 end
         end
         assert(outputs==7,'All right-bank outputs must still reach the central product belt')
         for _,bad in ipairs({'manual','unavailable','unrelated','quality','odd'})do
          local a,b=fixture();local o={transfer_mode=bad=='manual' and 'multiple' or 'auto',belt_in='belt',transport_quality=bad=='quality' and 'rare' or 'normal'}
          local c=bad=='unavailable' and {available={}}or catalog
          local next_id,changed=loops.apply(a,1,b,r,bad=='odd' and 13 or 14,o,100,c,{},bad=='unrelated' and {}or {batch=true})
          assert(next_id==100 and changed==0 and #a==8 and b.width==15,'Ineligible bank mutated: '..bad)
         end
        """)

    def test_timeout_never_counts_as_pass(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"):
            r = release.Runner(root=self.root)
            r.deadline = 0
            with self.assertRaises(release.ReleaseError):
                r.remaining()
            self.assertNotIn("complete", r.state)

    def test_edit_during_release_stops_snapshot(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"):
            r = release.Runner(root=self.root)
            (self.root / "control.lua").write_text("return 100")
            with self.assertRaises(release.ReleaseError):
                r.assert_snapshot()

    def test_repeated_install_preserves_files_and_rejects_pin(self):
        mods = self.root / "mods"
        mods.mkdir()
        listing = {"mods": [{"name": release.MOD, "enabled": True}]}
        (mods / "mod-list.json").write_text(json.dumps(listing))
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"):
            r = release.Runner(root=self.root)
            r.config = {"mods": str(mods)}
            r.archive = release.package(self.root / "out", self.values, "1.0.0")
            r.install()
            target = mods / r.archive.name
            stamp = target.stat().st_mtime_ns
            r.install()
            self.assertEqual(stamp, target.stat().st_mtime_ns)
            listing["mods"][0]["version"] = "0.1.0"
            (mods / "mod-list.json").write_text(json.dumps(listing))
            with self.assertRaises(release.ReleaseError):
                r.install()

    def test_failed_publication_never_claims_complete(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"), patch.dict(sys.modules, {"secrets_store": unittest.mock.Mock(read_secret=lambda _: "dummy")}), patch.object(release.Runner, "api", side_effect=release.ReleaseError("API unavailable")):
            r = release.Runner(root=self.root)
            with self.assertRaises(release.ReleaseError):
                r.publish()
            self.assertNotIn("complete", r.state)

    def test_native_failure_never_enters_cache(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"):
            r = release.Runner(root=self.root)
            r.config = {"output": str(self.root / "out")}
            with self.assertRaises(release.ReleaseError):
                r.check(native=True)
            self.assertFalse(any(load.get("native") for load in (json.loads(p.read_text()) for p in (self.root / "private/cache").glob("*.json"))))

    def test_api_refuses_credential_redirect_destination(self):
        with patch.object(release, "DATA", self.root / "private"), patch.object(release, "PRIVATE", self.root / "no-config"):
            r = release.Runner(root=self.root)
            for url in ("http://api.github.com/foo", "https://evil.invalid/token", "https://api.github.com.evil.invalid/foo"):
                with self.assertRaises(release.ReleaseError):
                    r.api("POST", url, "dummy-not-a-real-token")


if __name__ == "__main__":
    unittest.main()
