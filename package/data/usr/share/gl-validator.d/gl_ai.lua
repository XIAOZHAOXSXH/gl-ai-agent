--[[
  Parameter validator for the gl_ai RPC object.

  oui.rpc validates arguments *recursively* before dispatch, and its default
  string whitelist is '^[%w%. %-_:#/]-$'. That rejects essentially every real
  user message - Chinese text, punctuation, quotes, emoji - so a chat request
  failed with -32602 "Invalid params" before our code ever ran.

  Only one method matters now: `rpc`, the stable dispatch surface described in
  /usr/lib/oui-httpd/rpc/gl_ai. Its payload is

      { m = "<method>", p = { ... whatever that method takes ... } }

  and `p` is user data of arbitrary shape, so it cannot be pattern-matched
  here. Mapping it to `true` disables the generic check for this method.

  That is safe rather than merely permissive, because real validation lives in
  glai/tools.lua: every tool declares a schema and tools.validate() enforces
  type, range, length, enum and regex on each parameter before anything runs.
  Shell injection is not reachable either - tools call ubus with structured
  arguments and there is no shell path.

  The named aliases further down exist only so an nginx worker holding an older
  cached method table keeps working; they can go once every router has cycled
  its web tier.
]]
return {
    -- the one real entry point; user text is free-form
    rpc = true,

    -- session ids look like 20260930-101145-960776
    get_session = { id = "^[%w_%-]+$" },
    delete_session = { id = "^[%w_%-]+$" },
    approve = { id = "^[%w_%-]+$" },

    -- legacy aliases (these only ever carry ids, booleans or settings)
    get_config = true,
    set_config = true,
    test_connection = true,
    cancel = true,
    chat = true,
    poll = true,
    get_tools = true,
    get_capabilities = true,
    list_sessions = true,
    new_session = true,
    selftest = true,
    pending_approvals = true,
}
