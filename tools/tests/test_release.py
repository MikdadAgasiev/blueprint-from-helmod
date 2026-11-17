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
         local blocks={{recipe_node={ingredients={{type='fluid',name='water'}}}}}
         local result=search.fluid_first(options,blocks,'normal')
         assert(#result==4 and result[1].fluids_first and result[1].gap==2)
         assert(result[2].fluids_first and result[2].gap==4)
         assert(result[3]==options[1] and result[4]==options[2])
         assert(not options[1].fluids_first)
         assert(search.fluid_first(options,blocks,'thorough')==options)
         assert(search.fluid_first(options,{},'normal')==options)
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
