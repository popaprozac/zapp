import ../registry
import std/strutils   # contains(string, string) substring check

# registry.nim is a self-contained POD/libc module — no importc that the test
# can't link (the supervisor clock is libc gettimeofday). No stubs needed, unlike
# permissions_test (which stubs zapp_build_permissions_json).

proc test() =
  # ---- add (engine + name) + read back ------------------------------------
  doAssert zapp_worker_registry_add_full_with_engine_and_name(
    cstring"w-1", cstring"win-1", cstring"/x.mjs", 7, cstring"Greeter") >= 0
  doAssert zapp_worker_registry_get_engine(cstring"w-1") == 7
  doAssert $zapp_worker_registry_get_display_name(cstring"w-1") == "Greeter"

  # display name falls back to id when unset
  doAssert zapp_worker_registry_add_full_with_engine(
    cstring"w-2", cstring"win-1", cstring"/y.mjs", 7) >= 0
  doAssert $zapp_worker_registry_get_display_name(cstring"w-2") == "w-2"

  # display name of a NULL id is "", of an unregistered id is the id itself
  doAssert $zapp_worker_registry_get_display_name(cstring"nope") == "nope"

  # engine of a missing worker is -1 (resolver picks)
  doAssert zapp_worker_registry_get_engine(cstring"missing") == -1

  # ---- idempotent refresh-in-place (no double-alloc) ----------------------
  let slotA = zapp_worker_registry_add_full_with_engine(
    cstring"w-1", cstring"win-1", cstring"/x2.mjs", 2)
  doAssert slotA >= 0
  # same id refreshed: engine updated in place, name untouched
  doAssert zapp_worker_registry_get_engine(cstring"w-1") == 2
  doAssert $zapp_worker_registry_get_display_name(cstring"w-1") == "Greeter"

  # ---- add_full (engine defaults to -1) -----------------------------------
  doAssert zapp_worker_registry_add_full(
    cstring"w-3", cstring"win-2", cstring"/z.mjs") >= 0
  doAssert zapp_worker_registry_get_engine(cstring"w-3") == -1

  # ---- set_engine ----------------------------------------------------------
  zapp_worker_registry_set_engine(cstring"w-3", 6)
  doAssert zapp_worker_registry_get_engine(cstring"w-3") == 6

  # ---- list_json shape -----------------------------------------------------
  block:
    let raw = zapp_workers_registry_list_json()
    doAssert raw != nil
    let j = $raw
    c_free(raw)
    doAssert j.len > 0
    doAssert j[0] == '['
    doAssert j[^1] == ']'
    doAssert j.contains("\"id\":\"w-1\"")
    doAssert j.contains("\"name\":\"Greeter\"")     # w-1 has a name
    doAssert j.contains("\"id\":\"w-2\"")
    doAssert not j.contains("\"id\":\"w-2\",\"name\"")  # w-2 has no name key
    doAssert j.contains("\"id\":\"w-3\"")
    doAssert j.contains("\"engine\":\"zjs\"")        # w-2 engine 7
    doAssert j.contains("\"engine\":\"bare-jsc\"")   # w-1 engine 2
    doAssert j.contains("\"engine\":\"bare-hermes\"")  # w-3 engine 6
    doAssert not j.contains("\"shared\"")            # `shared` removed from the wire
    doAssert j.contains("\"scriptUrl\":\"/x2.mjs\"") # w-1 refreshed url
    doAssert j.contains("\"owners\":[\"win-1\"]")

  # ---- remove (clears active) ---------------------------------------------
  zapp_worker_registry_remove(cstring"w-1")
  doAssert zapp_worker_registry_get_engine(cstring"w-1") == -1

  # ---- fmt_compact_ms ------------------------------------------------------
  doAssert $zapp_fmt_compact_ms(500) == "500ms"
  doAssert $zapp_fmt_compact_ms(30000) == "30s"
  doAssert $zapp_fmt_compact_ms(1500) == "1.5s"
  doAssert $zapp_fmt_compact_ms(1000) == "1s"

  # ---- supervisor: set_policy + record_failure window + get_window_state --
  # no policy on w-2 yet => record returns 0 (ignore)
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 0
  # max=2, window=60000: 1st/2nd failure restart (1), 3rd gives up (2), stays 2
  zapp_worker_supervisor_set_policy(cstring"w-2", 2, 60000)
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 1
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 1
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 2
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 2   # gave-up sticks

  # window state reflects the counters
  block:
    var fc, cap, win: cint
    doAssert zapp_worker_supervisor_get_window_state(
      cstring"w-2", addr fc, addr cap, addr win) == 0
    doAssert fc == 3
    doAssert cap == 2
    doAssert win == 60000
  # missing worker => -1
  doAssert zapp_worker_supervisor_get_window_state(
    cstring"none", nil, nil, nil) == -1

  # set_policy resets the window (fail_count back to 0, gave_up cleared)
  zapp_worker_supervisor_set_policy(cstring"w-2", 1, 1000)
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 1   # 1st in fresh window
  doAssert zapp_worker_supervisor_record_failure(cstring"w-2") == 2   # exceeds max=1

  # window_ms <= 0 defaults to 60000
  zapp_worker_supervisor_set_policy(cstring"w-3", 3, 0)
  block:
    var fc, cap, win: cint
    doAssert zapp_worker_supervisor_get_window_state(
      cstring"w-3", addr fc, addr cap, addr win) == 0
    doAssert win == 60000

  # supervisor getters
  doAssert $zapp_worker_supervisor_get_script_url(cstring"w-2") == "/y.mjs"
  doAssert zapp_worker_supervisor_get_script_url(cstring"none") == nil
  doAssert $zapp_worker_supervisor_get_owner(cstring"w-2") == "win-1"
  doAssert $zapp_worker_supervisor_get_owner(cstring"none") == ""

  echo "registry ok"

test()
