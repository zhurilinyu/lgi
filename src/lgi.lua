--[[--

    Lgi bootstrapper.

    Author: Pavel Holejsovsky
    Licence: MIT

--]]--

local assert, setmetatable, getmetatable, type, pairs, pcall, string, rawget =
      assert, setmetatable, getmetatable, type, pairs, pcall, string, rawget
local bit = require 'bit'
local lua_package = package

-- Require core lgi utilities, used during bootstrap.
local core = require 'lgi._core'

module 'lgi'

-- Initial bootstrap phase, We have to set up proper dispose handler
-- for IBaseInfo records, otherwise the rest of this bootstrap code
-- will leak them.
do
   local unref_info = assert(core.find('base_info_unref'))
   local unref = core.get(unref_info)
   core.dispose['GIRepository.IBaseInfo'] = unref;

   -- Note that this is the only place when we need to explicitely
   -- unref any IBaseInfo, because unref_info was created *before*
   -- core.dispose contained unref handler for it.
   unref(unref_info)

   -- Since now any IBaseInfo record is automatically unrefed in its
   -- __gc metamethod.

   -- Make sure that Typelib structure is also properly freed when
   -- allocated (by bootstrap code).
   core.dispose['GIRepository.Typelib'] =
      core.get(assert(core.find('free', 'Typelib')))
end

-- Table with all loaded packages.  Its metatable takes care of loading
-- on-demand.  Created by C-side bootstrap.
local packages = core.packages

-- Package table for GIRepository, populated with basic methods
-- manually.  Later it will be converted to full-featured package.
local gi = {}
core.packages.GIRepository = gi

-- Loads given set of symbols into table.
local function get_symbols(into, symbols, container)
   for _, symbol in pairs(symbols) do
      into[symbol] = core.get(assert(core.find(symbol, container)))
   end
end

gi.IInfoType = {
   FUNCTION = 1,
   STRUCT = 3,
   ENUM = 5,
   FLAGS = 6,
   OBJECT = 7,
   INTERFACE = 8,
   CONSTANT = 9,
}

gi.IRepository = {}
get_symbols(gi.IRepository, { 'require', 'find_by_name', 'get_n_infos',
			      'get_info', 'get_dependencies',
			      'get_version', }, 'IRepository')
get_symbols(
   gi, {
      'base_info_get_type', 'base_info_is_deprecated',
      'base_info_get_name', 'base_info_get_namespace',
      'enum_info_get_n_values', 'enum_info_get_value',
      'value_info_get_value',
      'struct_info_is_gtype_struct',
      'struct_info_get_n_fields', 'struct_info_get_field',
      'struct_info_get_n_methods', 'struct_info_get_method',
      'interface_info_get_n_prerequisites', 'interface_info_get_prerequisite',
      'interface_info_get_n_methods', 'interface_info_get_method',
      'interface_info_get_n_constants', 'interface_info_get_constant',
      'object_info_get_parent',
      'object_info_get_n_interfaces', 'object_info_get_interface',
      'object_info_get_n_fields', 'object_info_get_field',
      'object_info_get_n_methods', 'object_info_get_method',
      'object_info_get_n_constants', 'object_info_get_constant',
      })

-- Metatable for bitflags tables, resolving arbitrary number to the
-- table containing symbolic names of contained bits.
local bitflags_mt = {}
function bitflags_mt.__index(bitflags, value)
   local t = {}
   for name, flag in pairs(bitflags) do
      if type(flag) == 'number' and bit.band(flag, value) == flag then
	 t[flag] = name
      end
   end
   return t
end

-- Similar metatable for enum tables.
local enum_mt = {}
function enum_mt.__index(enum, value)
   for name, val in pairs(enum) do
      if val == value then return name end
   end
end

-- Metatable for _inherits field of objects and interfaces, looks up
-- the symbol in all inherited elements.
local _inherits_mt = {}
function _inherits_mt.__index(_inherits, symbol)
   for _, inherited in pairs(_inherits) do
      local sym = inherited[symbol]
      if sym then return sym end
   end
end

-- Metatable for all elements which are able to inherit from another
-- elements though _inherits field. Looks up missing symbols in
-- inherited tables.
local inheriting_mt = {}
function inheriting_mt.__index(inheriting, symbol)
   return _inherits[symbol]
end

-- Table containing loaders for various GI types, indexed by
-- gi.IInfoType constants.
local typeloader = {}

-- Loads symbol into the specified package.
local function load_symbol(package, symbol)
   -- Lookup baseinfo of requested symbol in the repo.
   local info = gi.IRepository.find_by_name(nil, package._info.namespace,
					    symbol)
   -- Decide according to symbol type what to do.
   local value
   if info then
      if not gi.base_info_is_deprecated(info) then
	 local type = gi.base_info_get_type(info)
	 if typeloader[type] then
	    value = typeloader[type](package, info)
	 end
      end

      -- Cache the result.
      package[symbol] = value
   end

   return value
end

typeloader[gi.IInfoType.FUNCTION] =
   function(package, info)
      return core.get(info)
   end

typeloader[gi.IInfoType.CONSTANT] =
   function(package, info)
      return core.get(info)
   end

local function load_enum(info, meta)
   local value = {}

   -- Load all enum values.
   for i = 0, gi.enum_info_get_n_values(info) - 1 do
	    local mi = gi.enum_info_get_value(info, i)
	    value[string.upper(gi.base_info_get_name(mi))] =
	    gi.value_info_get_value(mi)
	 end

   -- Install metatable providing reverse lookup (i.e name(s) by
   -- value).
   setmetatable(value, meta)
   return value
end

typeloader[gi.IInfoType.ENUM] =
   function(package, info)
      return load_enum(info, enum_mt)
   end

typeloader[gi.IInfoType.FLAGS] =
   function(package, info)
      return load_enum(info, bitflags_mt)
   end

typeloader[gi.IInfoType.STRUCT] =
   function(package, info)
      local value

      -- Avoid exposing internal structs created for object implementations.
      if not gi.struct_info_is_gtype_struct(info) then
	 value = {}

	 -- Create table with all methods of the structure.
	 for i = 0, gi.struct_info_get_n_methods(info) - 1 do
	    local mi = gi.struct_info_get_method(info, i)
	    value[gi.base_info_get_name(mi)] = core.get(mi)
	 end

	 -- Load all fields.
	 for i = 0, gi.struct_info_get_n_fields(info) - 1 do
	    local mi = gi.struct_info_get_field(info, i)
	    value[gi.base_info_get_name(mi)] = mi
	 end

	 -- Try to find dispose method.	 Unfortunately, there seems to
	 -- be no systematic approach in typelibs, so we go for
	 -- heuristics; prefer 'unref', then 'free'.  If it does not
	 -- fit, specific package has to repair setting in its
	 -- postprocessing hook.
	 local name = package._info.namespace .. '.' ..
	    gi.base_info_get_name(info)
	 if not core.dispose[name] then
	    local disposer = value.unref
	    if disposer then
	       value.unref = nil
	    else disposer = value.free
	       if disposer then value.free = nil end
	    end
	    core.dispose[name] = disposer
	 end
      end
      return value
   end

local function load_by_info(into, package, info)
   local name = gi.base_info_get_name(info)
   local namespace = gi.base_info_get_namespace(info)
   local target_name, value
   if namespace == package._info.namespace then
      target_name = name
      value = package[name]
   else
      target_name = namespace .. '.' .. name
      value = packages[namespace][name]
   end
   into[target_name] = value
end

typeloader[gi.IInfoType.INTERFACE] =
   function(package, info)
      -- Load all interface methods.
      local value = {}
      for i = 0, gi.interface_info_get_n_methods(info) - 1 do
	 local mi = gi.interface_info_get_method(info, i)
	 value[gi.base_info_get_name(mi)] = core.get(mi)
      end

      -- Load all fields.
      for i = 0, gi.interface_info_get_n_fields(info) - 1 do
	 local mi = gi.interface_info_get_field(info, i)
	 value[gi.base_info_get_name(mi)] = mi
      end

      -- Load all prerequisites (i.e. inherited interfaces).
      value._inherits = setmetatable({}, _inherits_mt)
      for i = 0, gi.interface_info_get_n_prerequisites(info) - 1 do
	 local pi = gi.interface_info_get_prerequisite(info, i)
	 load_by_info(value._inherits, package, pi)
      end

      return setmetatable(value, inheriting_mt)
   end

typeloader[gi.IInfoType.OBJECT] =
   function(package, info)
      local value = {}
      -- Load all object methods.
      for i = 0, gi.object_info_get_n_methods(info) - 1 do
	 local mi = gi.object_info_get_method(info, i)
	 value[gi.base_info_get_name(mi)] = core.get(mi)
      end

      -- Load all constants.
      for i = 0, gi.object_info_get_n_constants(info) - 1 do
	 local mi = gi.object_info_get_constant(info, i)
	 value[gi.base_info_get_name(mi)] = core.get(mi)
      end

      -- Load all fields.
      for i = 0, gi.object_info_get_n_fields(info) - 1 do
	 local mi = gi.object_info_get_field(info, i)
	 value[gi.base_info_get_name(mi)] = mi
      end

      -- Load parent object.
      value._inherits = setmetatable({}, _inherits_mt)
      local pi = gi.object_info_get_parent(info)
      if pi then
	 load_by_info(value._inherits, package, pi)
      end

      -- Load implemented interfaces.
      for i = 0, gi.object_info_get_n_interfaces(info) - 1 do
	 local ii = gi.object_info_get_interface(info, i)
	 load_by_info(value._inherits, package, ii)
      end

      return setmetatable(value, inheriting_mt)
   end

-- Loads package, optionally with specified version and returns table which
-- represents it (usable as package table for Lua package loader).
local function load_package(package, namespace, version)

   -- Create package table with _info table containing auxiliary information
   -- and data for the package.
   if not package then
      package = {}
      packages[namespace] = package
   end
   package._info = { namespace = namespace, dependencies = {} }

   -- Load the typelibrary for the namespace.
   package._info.typelib = assert(gi.IRepository.require(
				     nil, namespace, version))
   package._info.version = version or
      gi.IRepository.get_version(nil, namespace)

   -- Load all package dependencies.
   for _, dep in pairs(gi.IRepository.get_dependencies(nil, namespace) or {}) do
      local name, version  = string.match(dep, '(.+)-(.+)')
      package._info.dependencies[name] = load_package(nil, name, version)
   end

   -- Install 'resolve' closure, which forces loading this namespace.
   -- Useful when someone wants to inspect what's inside (e.g. some
   -- kind of source browser or smart editor).
   package._info.resolve =
      function()
	 -- Iterate through all items in the namespace and dereference them,
	 -- which causes them to be loaded in and cached inside the package
	 -- table.
	 for i = 0, gi.IRepository.get_n_infos(nil, namespace) -1 do
	    local info = gi.IRepository.get_info(nil, namespace, i)
	    pcall(load_symbol, package, gi.base_info_get_name(info))
	 end
      end

   -- _info table serves also as a metatable for the package.
   package._info.__index = load_symbol
   return setmetatable(package, package._info)
end

-- Install metatable into packages table, so that on-demand loading works.
setmetatable(packages, { __index = function(packages, name)
				      return load_package(nil, name)
				   end })

-- Convert our poor-man's GIRepository package into full-featured one.
gi.IInfoType = nil
load_package(gi, 'GIRepository')

-- Install new loader which will load packages on-demand using
-- 'packages' table.
lua_package.loaders[#lua_package.loaders + 1] =
   function(name)
      local prefix, name = string.match(name, '(.+)%.(.+)')
      if prefix == 'lgi' then
	 local ok, result = pcall(load_package, packages, name)
	 if not ok or not result then return result end
	 return function() return result end
      end
   end
