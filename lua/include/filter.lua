local mod = {}

local dpdkc = require "dpdkc"
local device = require "device"
local ffi = require "ffi"
local dpdk = require "dpdk"
local mbitmask = require "bitmask"
local err = require "error"

mod.DROP = -1

local ETQF_BASE			= 0x00005128
local ETQS_BASE			= 0x0000EC00

local ETQF_FILTER_ENABLE	= bit.lshift(1, 31)
local ETQF_IEEE_1588_TIME_STAMP	= bit.lshift(1, 30)

local ETQS_RX_QUEUE_OFFS	= 16
local ETQS_QUEUE_ENABLE		= bit.lshift(1, 31)

local ETQF = {}
for i = 0, 7 do
	ETQF[i] = ETQF_BASE + 4 * i
end
local ETQS = {}
for i = 0, 7 do
	ETQS[i] = ETQS_BASE + 4 * i
end



local dev = device.__devicePrototype

ffi.cdef[[
struct rte_5tuple_filter {
	uint32_t dst_ip;         /**< destination IP address in big endian. */
	uint32_t src_ip;         /**< source IP address in big endian. */
	uint16_t dst_port;       /**< destination port in big endian. */
	uint16_t src_port;       /**< source Port big endian. */
	uint8_t protocol;        /**< l4 protocol. */
	uint8_t tcp_flags;       /**< tcp flags. */
	uint16_t priority;       /**< seven evels (001b-111b), 111b is highest,
				      used when more than one filter matches. */
	uint8_t dst_ip_mask:1,   /**< if mask is 1b, do not compare dst ip. */
		src_ip_mask:1,   /**< if mask is 1b, do not compare src ip. */
		dst_port_mask:1, /**< if mask is 1b, do not compare dst port. */
		src_port_mask:1, /**< if mask is 1b, do not compare src port. */
		protocol_mask:1; /**< if mask is 1b, do not compare protocol. */
};

int rte_eth_dev_add_5tuple_filter 	( 	uint8_t  	port_id,
		uint16_t  	index,
		struct rte_5tuple_filter *  	filter,
		uint16_t  	rx_queue 
	);
int
mg_5tuple_add_HWfilter_ixgbe(uint8_t port_id, uint16_t index,
			struct rte_5tuple_filter *filter, uint16_t rx_queue);
]]

-- FIXME: this function is highly device dependent
function dev:l2Filter(etype, queue)
  -- FIXME: ASK: device compatibility???
	if type(queue) == "table" then
		if queue.dev ~= self then
			error("Queue must belong to the device being configured")
		end
		queue = queue.qid
	end
	-- TODO: support for other NICs
	if queue == -1 then
		queue = 63
	end
	dpdkc.write_reg32(self.id, ETQF[1], bit.bor(ETQF_FILTER_ENABLE, etype))
	dpdkc.write_reg32(self.id, ETQS[1], bit.bor(ETQS_QUEUE_ENABLE, bit.lshift(queue, ETQS_RX_QUEUE_OFFS)))
end
--- Installs a 5tuple filter on the device.
--  Matching packets will be redirected into the specified rx queue
--  NOTE: this is currently only tested for X540 NICs, and will probably also
--  work for 82599 and other ixgbe NICs. Use on other NICs might result in
--  undefined behavior.
-- @param filter A table describing the filter. Possible fields are
--   src_ip    :  Sourche IPv4 Address
--   dst_ip    :  Destination IPv4 Address
--   src_port  :  Source L4 port
--   dst_port  :  Destination L4 port
--   l4protocol:  L4 Protocol type
--                supported protocols: ip.PROTO_ICMP, ip.PROTO_TCP, ip.PROTO_UDP
--                If a non supported type is given, the filter will only match on
--                protocols, which are not supported.
--  All fields are optional.
--  If a field is not present, or nil, the filter will ignore this field when
--  checking for a match.
-- @param queue RX Queue, where packets, matching this filter will be redirected
-- @param priority optional (default = 1) The priority of this filter rule.
--  7 is the highest priority and 1 the lowest priority.
function dev:addHW5tupleFilter(filter, queue, priority)
  local sfilter = ffi.new("struct rte_5tuple_filter")
  sfilter.src_ip_mask   = (filter.src_ip      == nil) and 1 or 0
  sfilter.dst_ip_mask   = (filter.dst_ip      == nil) and 1 or 0
  sfilter.src_port_mask = (filter.src_port    == nil) and 1 or 0
  sfilter.dst_port_mask = (filter.dst_port    == nil) and 1 or 0
  sfilter.protocol_mask = (filter.l4protocol  == nil) and 1 or 0

  sfilter.priority = priority or 1
  if(sfilter.priority > 7 or sfilter.priority < 1) then
    ferror("Filter priority has to be a number from 1 to 7")
    return
  end

  sfilter.src_ip    = filter.src_ip     or 0
  sfilter.dst_ip    = filter.dst_ip     or 0
  sfilter.src_port  = filter.src_port   or 0
  sfilter.dst_port  = filter.dst_port   or 0
  sfilter.protocol  = filter.l4protocol or 0
  --if (filter.l4protocol) then
  --  print "[WARNING] Protocol filter not yet fully implemented and tested"
  --end

  if self.filters5Tuple == nil then
    self.filters5Tuple = {}
    self.filters5Tuple.n = 0
  end
  self.filters5Tuple[self.filters5Tuple.n] = sfilter
  local idx = self.filters5Tuple.n
  self.filters5Tuple.n = self.filters5Tuple.n + 1

  local state
  if (self:getPciId() == device.PCI_ID_X540) then
    -- TODO: write a proper patch for dpdk
    state = ffi.C.mg_5tuple_add_HWfilter_ixgbe(self.id, idx, sfilter, queue.qid)
  else
    state = ffi.C.rte_eth_dev_add_5tuple_filter(self.id, idx, sfilter, queue.qid)
  end

  if (state ~= 0) then
    errorf("Filter not successfully added: %s", err.getstr(-state))
  end

  return idx
end

-- fdir support for layer 3/4 filters

-- todo: IP/port filter

--- Filter PTP time stamp packets by inspecting the PTP version and type field.
-- Packets with PTP version 2 are matched with this filter.
-- @arg offset the offset of the PTP version field
-- @arg mtype the PTP type to look for, default = 0
-- @arg ver the PTP version to look for, default = 2
function dev:filterTimestamps(queue, offset, ntype, ver)
	-- TODO: dpdk only allows to change this at init time
	-- however, I think changing the flex-byte offset field in the FDIRCTRL register can be changed at run time here
	-- (as the fdir table needs to be cleared anyways which is the only precondition for changing this)
	if type(queue) == "table" then
		queue = queue.qid
	end
	offset = offset or 21
	if offset ~= 21 then
		error("other offsets are not yet supported")
	end
	mtype = mtype or 0
	ver = ver or 2
	local value = value or bit.lshift(ver, 8) + mtype
	local filter = ffi.new("struct rte_fdir_filter")
	filter.flex_bytes = value
	local mask = ffi.new("struct rte_fdir_masks")
	mask.only_ip_flow = 1
	mask.flexbytes = 1
	dpdkc.rte_eth_dev_fdir_set_masks(self.id, mask)
	dpdkc.rte_eth_dev_fdir_add_perfect_filter(self.id, filter, 1, queue, 0)
end


-- FIXME: add protp mask!!
ffi.cdef [[
struct mg_5tuple_rule {
    uint8_t proto;
    uint32_t ip_src;
    uint8_t ip_src_prefix;
    uint32_t ip_dst;
    uint8_t ip_dst_prefix;
    uint16_t port_src;
    uint16_t port_src_range;
    uint16_t port_dst;
    uint16_t port_dst_range;

};

struct rte_acl_ctx * mg_5tuple_create_filter(int socket_id, uint32_t num_rules);
void mg_5tuple_destruct_filter(struct rte_acl_ctx * acl);
int mg_5tuple_add_rule(struct rte_acl_ctx * acx, struct mg_5tuple_rule * mgrule, int32_t priority, uint32_t category_mask, uint32_t value);
int mg_5tuple_build_filter(struct rte_acl_ctx * acx, uint32_t num_categories);
int mg_5tuple_classify_burst(
    struct rte_acl_ctx * acx,
    struct rte_mbuf **pkts,
    struct mg_bitmask* pkts_mask,
    uint32_t num_categories,
    uint32_t num_real_categories,
    struct mg_bitmask** result_masks,
    uint32_t ** result_entries
    );
uint32_t mg_5tuple_get_results_multiplier();
]]

local mg_filter_5tuple = {}
mod.mg_filter_5tuple = mg_filter_5tuple
mg_filter_5tuple.__index = mg_filter_5tuple

--- Creates a new 5tuple filter / packet classifier
-- @param socket optional (default: socket of calling thread), CPU socket, where memory for the filter should be allocated.
-- @param acx experimental use only. should be nil.
-- @param numCategories number of categories, this filter should support
-- @param maxNRules optional (default = 10), maximum number of rules.
-- @return a wrapper table for the created filter
function mod.create5TupleFilter(socket, acx, numCategories, maxNRules)
  socket = socket or select(2, dpdk.getCore())
  maxNRules = maxNRules or 10

  local category_multiplier = ffi.C.mg_5tuple_get_results_multiplier()

  local rest = numCategories % category_multiplier

  local numBlownCategories = numCategories
  if(rest ~= 0) then
    numBlownCategories = numCategories + category_multiplier - rest
  end

  local result =  setmetatable({
    acx = acx or ffi.gc(ffi.C.mg_5tuple_create_filter(socket, maxNRules), function(self)
      -- FIXME: why is destructor never called?
      print "5tuple garbage"
      ffi.C.mg_5tuple_destruct_filter(self)
    end),
    built = false,
    nrules = 0,
    numCategories = numBlownCategories,
    numRealCategories = numCategories,
    out_masks = ffi.new("struct mg_bitmask*[?]", numCategories),
    out_values = ffi.new("uint32_t*[?]", numCategories)
  }, mg_filter_5tuple)

  for i = 1,numCategories do
    result.out_masks[i-1] = nil
  end
  return result
end


--- Bind an array of result values to a filter category.
-- One array of values can be boun to multiple categories. After classification
-- it will contain mixed values of all categories it was bound to.
-- @param values Array of values to be bound to a category. May also be a number. In this case
--  a new Array will be allocated and bound to the specified category.
-- @param category optional (default = bind the specified array to all not yet bound categories),
--  The category the array should be bound to
-- @return the array, which was bound
function mg_filter_5tuple:bindValuesToCategory(values, category)
  if type(values) == "number" then
    values = ffi.new("uint32_t[?]", values)
  end
  if not category then
    -- bind bitmask to all categories, which do not yet have an associated bitmask
    for i = 1,self.numRealCategories do
      if (self.out_values[i-1] == nil) then
        print("assigned default at category " .. tostring(i))
        self.out_values[i-1] = values
      end
    end
  else
    print("assigned bitmask to category " .. tostring(category))
    self.out_values[category-1] = values
  end
  return values
end

--- Bind a BitMask to a filter category.
-- On Classification the corresponding bits in the bitmask are set, when a rule
-- matches a packet, for the corresponding category.
-- One Bitmask can be bound to multiple categories. The result will be a bitwise OR
-- of the Bitmasks, which would be filled for each category.
-- @param bitmask Bitmask to be bound to a category. May also be a number. In this case
--  a new BitMask will be allocated and bound to the specified category.
-- @param category optional (default = bind the specified bitmask to all not yet bound categories),
--  The category the bitmask should be bound to
-- @return the bitmask, which was bound
function mg_filter_5tuple:bindBitmaskToCategory(bitmask, category)
  if type(bitmask) == "number" then
    bitmask = mbitmask.createBitMask(bitmask)
  end
  if not category then
    -- bind bitmask to all categories, which do not yet have an associated bitmask
    for i = 1,self.numRealCategories do
      if (self.out_masks[i-1] == nil) then
        print("assigned default at category " .. tostring(i))
        self.out_masks[i-1] = bitmask.bitmask
      end
    end
  else
    print("assigned bitmask to category " .. tostring(category))
    self.out_masks[category-1] = bitmask.bitmask
  end
  return bitmask
end


--- Allocates memory for one 5 tuple rule
-- @return ctype object "struct mg_5tuple_rule"
function mg_filter_5tuple:allocateRule()
  return ffi.new("struct mg_5tuple_rule")
end

--- Adds a rule to the filter
-- @param rule the rule to be added (ctype "struct mg_5tuple_rule")
-- @priority priority of the rule. Higher number -> higher priority
-- @category_mask bitmask for the categories, this rule should apply
-- @value 32bit integer value associated with this rule. Value is not allowed to be 0
function mg_filter_5tuple:addRule(rule, priority, category_mask, value)
  if(value == 0) then
    error("ERROR: Adding a rule with a 0 value is not allowed")
  end
  self.buit = false
  return ffi.C.mg_5tuple_add_rule(self.acx, rule, priority, category_mask, value)
end

--- Builds the filter with the currently added rules. Should be executed after adding rules
-- @param optional (default = number of Categories, set at 5tuple filter creation time) numCategories maximum number of categories, which are in use.
function mg_filter_5tuple:build(numCategories)
  numCategories = numCategories or self.numRealCategories
  self.built = true
  --self.numCategories = numCategories
  return ffi.C.mg_5tuple_build_filter(self.acx, numCategories)
end

--- Perform packet classification for a burst of packets
-- Will do memory violation, when Masks or Values are not correctly bound to categories.
-- @param pkts Array of mbufs. Mbufs should contain valid IPv4 packets with a
--  normal ethernet header (no VLAN tags). A L4 Protocol header has to be
--  present, to avoid reading at invalid memory address. -- FIXME: check if this is true
-- @param inMask bitMask, specifying on which packets the filter should be applied
-- @return 0 on successfull completion.
function mg_filter_5tuple:classifyBurst(pkts, inMask)
  if not self.built then
    print("Warning: New rules have been added without building the filter!")
  end
  --numCategories = numCategories or self.numCategories
  return ffi.C.mg_5tuple_classify_burst(self.acx, pkts.array, inMask.bitmask, self.numCategories, self.numRealCategories, self.out_masks, self.out_values)
end

return mod

