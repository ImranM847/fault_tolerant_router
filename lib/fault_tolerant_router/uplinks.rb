class Uplinks

  def initialize(config)
    @uplinks = config.map { |uplink| Uplink.new(uplink) }
  end

  def each
    @uplinks.each { |uplink| yield uplink }
  end

  def active_uplinks
    @uplinks.find_all { |uplink| uplink.active }
  end

  def default_route_uplinks
    @uplinks.find_all { |uplink| uplink.default_route }
  end

  def any_up_state_changes?
    @uplinks.any? { |uplink| uplink.up_state_changed? }
  end

  def any_active_state_changes?
    @uplinks.any? { |uplink| uplink.active_state_changed? }
  end

  def all_default_route_uplinks_down?
    default_route_uplinks.all? { |uplink| !uplink.up }
  end

  def log_description(type)
    separator = type == :log ? '; ' : "\n"
    @uplinks.map { |uplink| uplink.log_description }.join(separator)
  end

  def initialize_routing_commands
    commands = []
    priorities = @uplinks.map { |uplink| uplink.priorities }.flatten.minmax
    tables = @uplinks.map { |uplink| uplink.table }.minmax

    #enable IP forwarding
    commands += ['echo 1 > /proc/sys/net/ipv4/ip_forward']

    #clean all previous configurations, try to clean more than needed (double) to avoid problems in case of changes in the
    #number of uplinks between different executions
    ((priorities.max - priorities.min + 2) * 2).times { |i| commands += ["ip rule del priority #{priorities.min + i} &> /dev/null"] }
    ((tables.max - tables.min + 2) * 2).times { |i| commands += ["ip route del table #{tables.min + i} &> /dev/null"] }

    #disable "reverse path filtering" on the uplink interfaces
    commands += ['echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter']
    commands += @uplinks.map { |uplink| "echo 2 > /proc/sys/net/ipv4/conf/#{uplink.interface}/rp_filter" }

    #set uplinks routes
    commands += @uplinks.map { |uplink| uplink.route_add_commands }

    #rule for first packet of outbound connections
    commands += ["ip rule add priority #{priorities.max + 1} from all lookup #{tables.max + 1}"]

    #set default route
    commands += default_route_commands

    #apply the routing changes
    commands += ['ip route flush cache']

    commands.flatten
  end

  def default_route_commands
    #do not use balancing if there is just one active uplink
    if active_uplinks.size == 1
      nexthops = "via #{active_uplinks.first.gateway}"
    else
      nexthops = active_uplinks.map do |uplink|
        #the "weight" parameter is optional
        tail = uplink.weight ? " weight #{uplink.weight}" : ''
        "nexthop via #{uplink.gateway}#{tail}"
      end
      nexthops = nexthops.join(' ')
    end
    #set the route for first packet of outbound connections
    ["ip route replace table #{@uplinks.map { |uplink| uplink.table }.max + 1} default #{nexthops}"]
  end

  def detect_ip_changes!
    results = @uplinks.map { |uplink| uplink.detect_ip_changes! }
    commands = results.map { |result| result[:commands] }.flatten
    if results.any? { |result| result[:active] && result[:gateway_changed] }
      commands += default_route_commands
    end
    #apply the routing changes, in any
    commands += ['ip route flush cache'] if commands.any?
    commands
  end

  def test_routing!
    @uplinks.each { |uplink| uplink.test_routing! }

    if all_default_route_uplinks_down?
      default_route_uplinks.each { |uplink| uplink.active = true }
      puts 'No default route uplink seems to be up: enabling them all!' if DEBUG
    end

    @uplinks.each { |uplink| puts uplink.debug_description } if DEBUG
  end

end
