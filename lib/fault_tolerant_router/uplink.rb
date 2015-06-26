class Uplink
  attr_reader :default_route, :description, :fwmark, :gateway, :id, :interface, :ip, :priority1, :table, :type, :up, :weight
  attr_accessor :priority2, :routing

  def initialize(config, id)
    @id = id
    @priority1 = BASE_PRIORITY + @id
    @table = BASE_TABLE + @id
    @fwmark = BASE_FWMARK + @id
    @interface = config['interface']
    raise "Uplink interface not specified: #{config}" unless @interface
    @type = case config['type']
              when 'static'
                :static
              when 'ppp'
                :ppp
              else
                raise "Uplink type not valid: #{config}"
            end
    @description = config['description']
    raise "Uplink description not specified: #{config}" unless @description
    @weight = config['weight']
    @default_route = config['default_route'].nil? ? true : config['default_route']

    #a new uplink is supposed to be up
    @up = true
    #a new uplink starts as routing if it's marked as a default route
    @routing = @default_route

    if @type == :static
      @ip = config['ip']
      raise "Uplink IP address not specified: #{config}" unless @ip
      @gateway = config['gateway']
      raise "Uplink gateway not specified: #{config}" unless @gateway
    else
      detect_ppp_ips!
      puts "Uplink #{@description}: initialized with [ip: #{@ip}, gateway: #{@gateway}]" if DEBUG
    end
  end

  def detect_ppp_ips!
    @previous_ip = @ip
    @previous_gateway = @gateway
    if DEMO
      @ip = %w(3.0.0.101 3.0.0.102).sample
      @gateway = %w(3.0.0.1 3.0.0.2).sample
    else
      ifaddr = Socket.getifaddrs.find { |i| i.name == @interface && i.addr && i.addr.ipv4? }
      if ifaddr
        @ip = ifaddr.addr.ip_address
        @gateway = ifaddr.dstaddr.ip_address
      else
        #todo: what to do if it happens?
        raise 'PPP IP address not found'
      end
    end
  end

  def detect_ip_changes!
    #todo: log ip changes
    commands = []
    if @type == :ppp
      detect_ppp_ips!
      if @previous_ip != @ip || @previous_gateway != @gateway
        puts "Uplink #{@description}: IP change [ip: #{@previous_ip}, gateway: #{@previous_gateway}] --> [ip: #{@ip}, gateway: #{@gateway}]" if DEBUG
        commands = [
            [
                "ip rule del priority #{@priority1}",
                "ip rule del priority #{@priority2}"
            ],
            route_add_commands
        ].flatten
      end
    end
    need_default_route_update = @routing && (@previous_gateway != @gateway)
    [commands, need_default_route_update]
  end

  def ping(ip_address)
    if DEMO
      sleep 0.1
      rand(3) > 0
    else
      `ping -n -c 1 -W 2 -I #{@ip} #{ip_address}`
      $?.to_i == 0
    end
  end

  def test_routing!
    #save current state
    @previously_up = @up
    @previously_routing = @routing

    @successful_tests = 0
    @unsuccessful_tests = 0

    #for each test (in random order)...
    TEST_IPS.shuffle.each_with_index do |test, i|
      successful_test = false

      #retry for several times...
      PING_RETRIES.times do
        if DEBUG
          print "Uplink #{@description}: ping #{test}... "
          STDOUT.flush
        end
        if ping(test)
          successful_test = true
          puts 'ok' if DEBUG
          #avoid more pings to the same ip after a successful one
          break
        else
          puts 'error' if DEBUG
        end
      end

      if successful_test
        @successful_tests += 1
      else
        @unsuccessful_tests += 1
      end

      #if not currently doing the last test...
      if i + 1 < TEST_IPS.size
        if @successful_tests >= REQUIRED_SUCCESSFUL_TESTS
          puts "Uplink #{@description}: avoiding more tests because there are enough positive ones" if DEBUG
          break
        elsif TEST_IPS.size - @unsuccessful_tests < REQUIRED_SUCCESSFUL_TESTS
          puts "Uplink #{@description}: avoiding more tests because too many have been failed" if DEBUG
          break
        end
      end

    end

    @up = @successful_tests >= REQUIRED_SUCCESSFUL_TESTS
    @routing = @up && @default_route
    routing_state_changed = @routing != @previously_routing

    state = @previously_up ? 'up' : 'down'
    state += " --> #{@up ? 'up' : 'down'}" if @up != @previously_up
    routing = @previously_routing ? 'enabled' : 'disabled'
    routing += " --> #{@routing ? 'enabled' : 'disabled'}" if @routing != @previously_routing
    log_message="Uplink #{@description}: #{state}"
    debug_message = "Uplink #{@description}: #{@successful_tests} successful tests, #{@unsuccessful_tests} unsuccessful tests, state #{state}, routing #{routing}"

    [routing_state_changed, log_message, debug_message]
  end

  def route_add_commands
    #- locally generated packets having as source ip the ethX ip
    #- returning packets of inbound connections coming from ethX
    #- non-first packets of outbound connections for which the first packet has been sent to ethX via multipath routing
    [
        "ip route replace table #{table} default via #{@gateway} src #{@ip}",
        "ip rule add priority #{@priority1} from #{@ip} lookup #{table}",
        "ip rule add priority #{@priority2} fwmark #{fwmark} lookup #{table}"
    ]
  end

end
