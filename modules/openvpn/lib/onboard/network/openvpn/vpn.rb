autoload :TCPSocket,  'socket'
autoload :Time,       'time'
autoload :UUID,       'uuid'
autoload :Timeout,    'timeout'

require 'onboard/extensions/ipaddr'
require 'onboard/extensions/openssl'

require 'onboard/system/process'
require 'onboard/network/interface'
require 'onboard/network/routing/table'
require 'onboard/network/openvpn/process'

autoload :Log,        'onboard/system/log'

class OnBoard
  module Network
    module OpenVPN
      class VPN

        System::Log.register_category 'openvpn', 'OpenVPN'

        def self.save
          @@all_vpn = getAll() unless (
              class_variable_defined? :@@all_vpn and @@all_vpn)
          File.open(
              ROOTDIR + '/etc/config/network/openvpn/vpn/vpn.dat', 
              'w'
          ) do |f|
            f.write(
              Marshal.dump(
                @@all_vpn.map do |vpn| 
                  vpn_data_internal = vpn.instance_variable_get(:@data_internal)
                  {
                    :process        => vpn_data_internal['process'],
                    :conffile       => vpn_data_internal['conffile'],
                    :start_at_boot  => vpn.data['running']
                  } 
                end
              )
            )
          end
        end

        def self.restore
          datafile = ROOTDIR + '/etc/config/network/openvpn/vpn/vpn.dat'
          return false unless File.readable? datafile
          current_VPNs = getAll()
          Marshal.load(File.read datafile).each do |h|
            if current_vpn = current_VPNs.detect{ |x| 
                h[:process].portable_id == x.data['portable_id'] }
              next if current_vpn.data['running'] 
              current_vpn.start() if h[:start_at_boot] 
            else
              new_vpn = new(h)
              new_vpn.start() if h[:start_at_boot] 
              @@all_vpn << new_vpn
            end
          end
        end
    
        # get info on running OpenVPN instances
        def self.getAll

          @@all_interfaces  = Network::Interface.getAll()
          @@all_routes      = Network::Routing::Table.getCurrent()
          @@all_vpn         = [] unless ( 
              class_variable_defined? :@@all_vpn and @@all_vpn)

          @@all_vpn.each do |vpn|
            vpn.set_not_running # ...until we'll find it actually running ;)
          end

          `pidof openvpn`.split.each do |pid|
            conffile = ''
            p = OpenVPN::Process.new(pid)
            if p.cmdline.length == 2
              p.cmdline.insert 1, '--config' # "sanitize" command line
            end
            p.cmdline.each_with_index do |arg, idx|
              next if idx == 0
              if p.cmdline[idx - 1] =~ /^\s*\-\-config/ 
                conffile = arg
                break
               end
            end
            self.new(
              :process  => p,
              :conffile => conffile,
              :running  => true
            ).add_to_the_pool
          end
          @@all_vpn.each_with_index do |vpn,i|
            vpn.data['human_index'] = i + 1
          end
          return @@all_vpn
        end

        def self.all_cached; @@all_vpn; end

        def self.start_from_HTTP_request(params)
          reserve_a_tcp_port = TCPServer.open('127.0.0.1', 0)
          reserved_tcp_port = reserve_a_tcp_port.addr[1] 
          cmdline = []
          cmdline << 'openvpn'
          cmdline << '--management' << '127.0.0.1' << reserved_tcp_port.to_s
          cmdline << '--daemon'
          logfile = "/var/log/ovpn-#{UUID.generate}.log" 
          cmdline << '--log-append' << logfile
          cmdline << '--ca' << case params['ca']
              when '__default__'
                Crypto::SSL::CACERT
              else
                "'#{Crypto::SSL::CERTDIR}/#{params['ca']}.crt'"
              end
          cmdline << '--cert' << 
              "'#{Crypto::SSL::CERTDIR}/#{params['cert']}.crt'"
          keyfile = "#{Crypto::SSL::KEYDIR}/#{params['cert']}.key"
          key = OpenSSL::PKey::RSA.new File.read keyfile
          dh = "#{Crypto::SSL::DIR}/dh#{key.size}.pem"
          cmdline << '--key' << "'#{keyfile}'" 
          crlfile = case params['ca']
          when '__default__'
            Crypto::EasyRSA::CRL
          else
            "'#{Crypto::SSL::CERTDIR}/#{params['ca']}.crl'"
          end
          cmdline << '--crl-verify' << crlfile if File.exists? crlfile
          cmdline << '--dev' << 'tun'
          cmdline << '--proto' << params['proto']
          if params['server_net'] # it's a server
            net = IPAddr.new params['server_net']
            cmdline << '--server' << net.to_s << net.netmask.to_s
            cmdline << '--port' << params['port'].to_s
            cmdline << '--keepalive' << '10' << '120' # suggested in OVPN ex.
            cmdline << '--dh' << dh # Diffie Hellman params :-)
          elsif params['remote_host'] # it's a client
            cmdline << 
                '--client' << '--nobind'
            cmdline << 
                '--remote' << params['remote_host'] << params['remote_port']
            cmdline << '--ns-cert-type' << 'server' if 
                params['ns-cert-type_server'] =~ /on|yes|true/
          end
          reserve_a_tcp_port.close
          msg = System::Command.run <<EOF
sudo touch #{logfile}
sudo chown :onboard #{logfile}
sudo chmod g+rw #{logfile}
cd /
sudo -E #{cmdline.join(' ')} # -E is important!
EOF
          msg[:log] = logfile
          System::Log.register({
            'path'      => logfile,
            'category'  => 'openvpn',
            'hidden'    => true
          })
          return msg
        end

        def self.modify_from_HTTP_request(params) 
          vpn = nil
          if    params['portable_id'] and params['portable_id'] =~ /\S/
            vpn = @@all_vpn.detect do |x| 
              x.data['portable_id'] == params['portable_id'] 
            end
          end
          if vpn  # the VPN has been found by portable_id (preferred method)
            if params['stop']
              return vpn.stop()
            elsif params['start']
              return vpn.start()
            end
          elsif params['stop'] # try to seek the right VPN by array index
            i = params['stop'].to_i - 1 
                # array index = "human-friendly index" - 1
            return @@all_vpn[i].stop()
          elsif params['start']
            i = params['start'].to_i - 1 
                # array index = "human-friendly index" - 1
            return @@all_vpn[i].start()
          end
        end

        attr_reader :data
        attr_writer :data

        def initialize(h) 
          @data_internal = {
            'process'   => h[:process],
            'conffile'  => h[:conffile]
          }
          @data = {'running' => h[:running]} 
          @data['portable_id'] = @data_internal['process'].portable_id 
          parse_conffile() if File.file? @data_internal['conffile'] # regular
          parse_conffile(:text => cmdline2conf())  
          if @data['server']
            if @data_internal['status'] 
              parse_status() 
              set_portable_client_list_from_status_data()
              # TODO?: get client info (and certificate info) 
              # through --client-connect ?
            end
            parse_ip_pool() if @data_internal['ifconfig-pool-persist'] 
          elsif @data['client'] 
            @data['client'] = {} unless @data['client'].respond_to? :[]
            if @data_internal['management']
              begin
                Timeout::timeout(3) do # three seconds should be fair
                  get_client_info_from_management_interface()
                end
              rescue Timeout::Error
                @data['client']['management_interface_err'] = $!.to_s
              end
            else
              @data['client']['management_interface_warn'] = 'OpenVPN Management Interface unavailable for this client connection'
            end
          end
          find_virtual_address()
          find_interface()
          find_routes()
        end

        def start
          if @data['running'] # TODO?: these are 'cached' data... "update"?
            return {:err => 'Already started.'}
          else
            pwd = @data_internal['process'].env['PWD']
            cmd = @data_internal['process'].cmdline.join(' ')
            cmd += ' --daemon' unless @data_internal['daemon']
            msg = System::Command.bgexec ("cd #{pwd} && sudo -E #{cmd}") 
            msg[:ok] = true
            msg[:info] = 'Request accepted. You may check <a href="">this page</a> again to get updated info for the active VPNs. You may also check the <a href="/system/logs.html">logs</a>.'
            return msg
          end          
        end

        def stop(*opts)
          msg = ''
          if @data['running'] # TODO?: these are 'cached' data... "update"?
            msg = System::Command.run(
               "kill #{@data_internal['process'].pid}", :sudo)
          end
          if opts.include? :rmlog
            logfile = @data_internal['log'] || @data_internal['log-append']
            if File.exists? logfile
              System::Command.run "rm #{logfile}", :sudo
              System::Log.all.delete_if { |h| h['path'] == logfile }
            end
          end
          return msg
        end
       
        def set_not_running
          @data['running'] = false
        end

        def add_to_the_pool
          already_in_the_pool = false
          @@all_vpn.each_with_index do |vpn, vpn_i|
            if (
                vpn.data_internal['process'].cmdline ==
                    self.data_internal['process'].cmdline and
                vpn.data_internal['process'].env['PWD'] ==
                    self.data_internal['process'].env['PWD']
            )
              @@all_vpn[vpn_i] = self
              already_in_the_pool = true
              break
            end
          end
          unless already_in_the_pool
            @@all_vpn << self
          end
        end

        
        # Turn the OpenVPN command line into a "virtual" configuration file
        def cmdline2conf
          line_ary = []
          text = ""
          @data_internal['process'].cmdline.each do |arg|
            if arg =~ /\-\-(\S+)/ 
              text << line_ary.join(' ') << "\n" if line_ary.length > 0
              line_ary = [$1] 
            elsif line_ary.length > 0
              line_ary << arg
            end
          end
          text << line_ary.join(' ') << "\n" if line_ary.length > 0
          return text
        end

        def find_interface
          interface = @@all_interfaces.detect do |iface|
            if iface.ip
              iface.ip.detect do |ip|
                ip.addr.to_s == @data['virtual_address']
              end
            else
              nil
            end
          end
          @data['interface'] = interface.name if interface
        end

        def find_virtual_address
          if @data['client']
            begin
              @data['virtual_address'] = @data['client']['Virtual Address']
            rescue NoMethodError, TypeError
            end
          elsif data['server']
            @data['virtual_address'] = IPAddr.new(
                "#{@data['server']}/#{data['netmask']}"
            ).to_range.to_a[1].to_s
          end
        end


        def find_routes
          ary = []
          @@all_routes.routes.each do |route|
            if  @data['interface'] and
                @data['interface'] =~ /\S/ and
                @data['interface'] == route.data['dev']
              ary << route.data
            end
          end
          data['routes'] = ary
        end

        def parse_conffile(opts={})  
          text = nil
          if opts[:text]
            text = opts[:text]
          else
            if opts[:file]
              conffile = find_file opts[:file]
            else
              conffile = find_file @data_internal['conffile']
            end 
            begin
              text = File.read conffile 
            rescue
              @data['err'] = "couldn't open config file: '#{conffile}'"
              if @data_internal['conffile'] =~ /\S/
                @data['err'] << " '#{@data_internal['conffile']}'"
              end
              return false
            end    
          end      
            
          text.each_line do |line|
=begin
# this is a comment
#this too
a_statement # this is a comment # another comment
address#port # 'port' was not a comment (for example, dnsmasq config files) 
=end
            next if line =~ /^\s*[;#]/
            line.sub! /\s+[;#].*$/, '' 

            # "public" options with no arguments ("boolean" options)
            %w{duplicate-cn client-to-client client}.each do |optname|
              if line =~ /^\s*#{optname}\s*$/
                @data[optname] = true
                next
              end
            end 

            # "public" options with 1 argument 
            %w{port proto dev max-clients local}.each do |optname|
              if line =~ /^\s*#{optname}\s+(.*)\s*$/ 
                @data[optname] = $1
                next
              end
            end

            # "public" options with more arguments
            if line =~ /^\s*server\s+(\S+)\s+(\S+)/
              @data['server']             = $1
              @data['netmask']            = $2
              next
            elsif line =~ /^\s*remote\s+(\S+)\s+(\S+)/
              @data['remote']             = {}
              @data['remote']['address']  = $1
              @data['remote']['port']     = $2
              next
            end

            # "private" options with no args
            %w{daemon}.each do |optname|
              if line =~ /^\s*#{optname}\s*$/
                @data_internal[optname] = true
                next
              end
            end 

            # "private" options with 1 argument
            %w{key dh ifconfig-pool-persist status status-version log log-append}.each do |optname|
              if line =~ /^\s*#{optname}\s+(\S+)\s*$/
                @data_internal[optname] = $1
                if optname == 'log' or optname == 'log-append'
                  logfile = find_file $1
                  System::Log.register({
                      'path' => logfile, 
                      'category' => 'openvpn',
                      'hidden' => false
                  })
                end
                next
              end
            end

            %w{ca cert}.each do |optname|
              if line =~ /^\s*#{optname}\s+(\S+)\s*$/ 
                if file = find_file($1)
                  begin
                    c = OpenSSL::X509::Certificate.new(File.read file)
                    @data_internal[optname] = c

                    # NOTE: this is a 'lossy' conversion (name_val_type[2] is lost)
                    # I guess we won't need the "type" "field".
                    #
                    # c.issuer.to_a and c.subject.to_a are Arrays made up of
                    # Arrays of three elements each
                    issuer__to_h = {}
                    c.issuer.to_a.each do |name_val_type|
                      issuer__to_h[name_val_type[0]] = name_val_type[1]
                    end
                    subject__to_h = {}
                    c.subject.to_a.each do |name_val_type|
                      subject__to_h[name_val_type[0]] = name_val_type[1] 
                    end
                    @data[optname] = {
                      'serial'      => c.serial.to_i,
                      'issuer'      => issuer__to_h,
                      'subject'     => subject__to_h,
                      'not_before'  => c.not_before,
                      'not_after'   => c.not_after
                    }
                  rescue OpenSSL::X509::CertificateError
                    @data_internal[optname] = $!
                    @data[optname] = {'err' => $!.to_s} 
                  end
                  next
                else
                  @data_internal[optname] = Errno::ENOENT
                  @data[optname] = {'err' => "File not found or not readable: #{$1}"}
                end
              end
            end

            # "private" options with 2 args
            if line =~ /^\s*status\s+(\S+)\s+(\S+)\s*$/
              @data_internal['status'] = $1
              @data_internal['status_update_seconds'] = $2
              next
            elsif line =~ /^\s*keepalive\s+(\S+)\s+(\S+)\s*$/
              @data_internal['keepalive'] = {
                'interval'  => $1,
                'timeout'   => $2
              }
              @data_internal['ping'] = @data_internal['keepalive'] # an alias..
            elsif line =~ /^\s*management\s+(\S+)\s+(\S+)\s*$/
              address = $1
              port = $2
              address = '127.0.0.1' if 
                  address =~ /(\*|0\.0\.0\.0|::)/ and not
                  address =~ /[a-f\d]::/i and not
                  address =~ /::[a-f\d]/i
                # if "listen on any" (not recommended, though) is set,
                # this doesn't mean we will telnet to 0.0.0.0 or :: ;-)
              @data_internal['management'] = {
                'address' => address,
                'port'    => port
              }
              # TODO: configuration of the management interface may be more 
              # complicated than that! See OpenVPN docs.
            elsif line =~ /^\s*ifconfig\s+(\S+)\s+(\S+)\s*$/
              @data_internal['ifconfig'] = {
                'address'                 => $1,
                'remote_peer_or_netmask'  => $2
              }
            end

            # TODO or not TODO
            # TODO? server-bridge
            # TODO? push routes
            # TODO? client-config-dir, route
            # TODO? push "redirect-gateway def1 bypass-dhcp"

          end
          if @data_internal['status'] and not @data_internal['status-version']
            @data_internal['status-version'] = '1'
          end
        end

        def parse_status
          @data_internal['status_data'] = {}
          @data_internal['status_data']['client_list'] = {}
          @data_internal['status_data']['client_list']['clients'] = []
          @data_internal['status_data']['routing_table'] = {}
          @data_internal['status_data']['routing_table']['routes'] = []

          status_file = find_file @data_internal['status']

          unless status_file 
            @data_internal['status_data']['err'] = 'no readable status file has been found'
            return false
          end

          case @data_internal['status-version']
          when /1/
            parse_status_v1(status_file)
          when /2/
            parse_status_v2(status_file)
          else 
            raise \
                RuntimeError, 
                '@data_internal[\'status-version\'] was not set!'
          end
        end

        def parse_status_v1(status_file)
          where                     = :beginning
          got_client_list_header    = false
          got_routing_table_header  = false
          got_global_stats_header   = false
          client_list_fields        = []
          routing_table_fields     = []

          File.foreach(status_file) do |line|
            line.strip!

            where = :client_list    if line =~ /OpenVPN CLIENT LIST/
            where = :routing_table  if line =~ /ROUTING TABLE/
            where = :global_stats   if line =~ /GLOBAL STATS/ 

            if line =~ /^\s*Updated,(\S.*\S)\s*$/
              @data_internal['status_data']['updated'] = $1
            end

            if where == :client_list
              if line =~ /Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since/
                got_client_list_header = true
                client_list_fields = line.split(',') 
              elsif got_client_list_header
                h = {}
                values = line.split(',')
                break unless values.length == client_list_fields.length
                client_list_fields.each_with_index do |name, idx|
                  h[name] = values[idx]
                end
                @data_internal['status_data']['client_list']['clients'] << h
              end
            end

            if where == :routing_table
              if line =~ /Virtual Address,Common Name,Real Address,Last Ref/
                got_routing_table_header = true
                routing_table_fields = line.split(',') 
              elsif got_routing_table_header
                h = {}
                values = line.split(',')

                break unless 
                    values.respond_to? :length and
                    routing_table_fields.respond_to? :length and
                    values.length == routing_table_fields.length

                routing_table_fields.each_with_index do |name, idx|
                  h[name] = values[idx]
                end
                @data_internal['status_data']['routing_table']['routes'] << h
              end
            end

            # TODO? GLOBAL STATS?
           
          end
        end

        def parse_status_v2(status_file) # TODO: DRY
          headers = {}
          File.foreach(status_file) do |line|
            line.strip!

            if line =~ /TIME,([^,]+)/
              @data_internal['status_data']['updated'] = $1
            elsif line =~ /^HEADER,([^,]+),(.*)$/
              headers[$1] = $2.split(',') 
            elsif line =~ /^CLIENT_LIST,(.*)/
              values = $1.split(',')
              h = {}
              headers['CLIENT_LIST'].each_with_index do |hdr, idx|
                h[hdr] = values[idx]
              end
              @data_internal['status_data']['client_list']['clients'] << h
            elsif line =~ /^ROUTING_TABLE,(.*)/
              values = $1.split(',')
              h = {}
              headers['ROUTING_TABLE'].each_with_index do |hdr, idx|
                h[hdr] = values[idx]
              end
              @data_internal['status_data']['routing_table']['routes'] << h
            end

            # TODO? GLOBAL STATS?
           
          end
        end       

        def set_portable_client_list_from_status_data
          ary = []

          case @data_internal['status-version'].to_s
          when /1/
            ary = @data_internal['status_data']['client_list']['clients'].dup
            ary.each do |client|
              # the term 'route' is somewhat confusing; it's used in
              # the status file...
              route = @data_internal['status_data']['routing_table']['routes'].detect { |x| x['Real Address'] == client['Real Address'] }
              client['Virtual Address'] = route['Virtual Address'].dup
              client['Connected Since'] = Time.parse client['Connected Since']
            end
          when /2/
            ary = @data_internal['status_data']['client_list']['clients'].dup
            ary.each do |client|
              t = client['Connected Since (time_t)'].to_i
              if t > 0
                client['Connected Since'] = 
                    Time.at t
              else
                client['Connected Since'] =
                    Time.parse client['Connected Since']
              end 
              # creating a Time object from a Unix timestamp should be
              # more efficient than parsing a human readable string, so
              # use the former when available
            end
          else
            raise RuntimeError, "status-version should be either 1 or 2, got #{@data_internal['status-version']}"
          end

          @data['clients'] = ary

        end

        def parse_ip_pool
          @data['ip_pool'] = {
            'err' => nil,
            'pool' => []
          }

          ip_pool_file = find_file @data_internal['ifconfig-pool-persist']

          unless ip_pool_file 
            @data['ip_pool']['err'] = "no readable IP pool file has been found -- @data_internal['ifconfig-pool-persist'] = #{@data_internal['ifconfig-pool-persist']}"
            return false
          end

          File.foreach(ip_pool_file) do |line|
            line.strip!
            h = {}
            h['Common Name'], h['Virtual Address'] = line.split(',') 
            @data['ip_pool']['pool'] << h
          end
        end

        def get_client_info_from_management_interface
          begin
            tcp = TCPSocket.new(
                @data_internal['management']['address'],
                @data_internal['management']['port']
            )
          rescue
            @data['client'] = {} unless @data['client'].respond_to? :[] 
            @data_internal['management']['err'] = $!
            @data['client']['management_interface_err'] = $!.to_s
            return false
          end

          tcp.gets =~ /OpenVPN Management Interface/ or return false
          # gets the 'banner', or fails...

          tcp.puts 'state'
          @data_internal['management']['state'] = tcp.gets.strip.split(',')
          @data_internal['management']['status'] = {}
          until tcp.gets.strip == 'END'; end

          tcp.puts 'status'
          loop do
            line = tcp.gets.strip
            break if line == 'END'
            keyval = line.split(',')
            if keyval.length == 2
              key, val = keyval
              @data_internal['management']['status'][key] = val
            end
          end
          tcp.puts 'exit'          
          tcp.close

          @data['client'] = {
            # 'Common Name'           => 
            #     TODO: an OpenSSL/TLS/x509 class ? ,
            'Virtual Address'         => 
                @data_internal['management']['state'][3],
            'Bytes Received'          => 
                @data_internal['management']['status']['TCP/UDP read bytes'],
            'Bytes Sent'              =>
                @data_internal['management']['status']['TCP/UDP write bytes'],
            'Connected Since'          => Time.at(
                @data_internal['management']['state'][0].to_i)
          }
        end

        def logfile
          find_file(@data_internal['log'] || @data_internal['log-append'])
        end

        protected

        def data_internal
          @data_internal
        end

        private

        # Find out the right path to config files, status logs etc.
        def find_file(name)
          attempts = []
          attempts << name
          attempts << File.join(
              @data_internal['process'].env['PWD'], 
              name
          ) if @data_internal['process'].env['PWD']
          
          unless @data_internal['conffile'].strip == name.strip
            attempts << File.join(
              File.dirname(@data_internal['conffile']),
              name
            )
          end

          attempts.each do |attempt|
            return attempt if File.readable? attempt
          end

          return false
        end

      end
    end
  end
end
