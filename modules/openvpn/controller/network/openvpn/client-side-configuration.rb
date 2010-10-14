require 'facets/hash'
require 'sinatra/base'

class OnBoard

  class Controller < Sinatra::Base

    get '/network/openvpn/client-side-configuration.:format' do
      all_vpns                = Network::OpenVPN::VPN.getAll
      #all_interfaces          = nil
      ## use cached data if possible
      #if Network::OpenVPN::VPN.class_variables.include? :@@all_interfaces
      #  all_interfaces = 
      #      Network::OpenVPN::VPN.class_variable_get :@@all_interfaces
      #  if !(all_interfaces.respond_to? :length and all_interfaces.length > 0)
      #    all_interfaces = Network::Interface.getAll
      #  end
      #end
      objects = {
        :vpns               => all_vpns.select{|v| v.data['server']}, 
        :network_interfaces => :unused # was: all_interfaces
      }
      format(
        :module   => 'openvpn',
        :path     => '/network/openvpn/client-side-configuration',
        :format   => params[:format], 
        :objects  => objects,
        :title    => 'Cient-side configuration Wizard'
      )
    end

    get '/network/openvpn/client-side-configuration/howto.:format' do
      vpn = Network::OpenVPN::VPN.getAll.detect do |vpn_| 
        vpn_.data['uuid'] == params['vpn_uuid']
      end
      certs = Crypto::SSL::getAllCerts.select do |key, value| # Facets 
        cert = value['cert']
        cert['issuer'] == vpn.data['ca']['subject'] and not
        cert['subject'] == vpn.data['cert']['subject'] 
            # exclude the server cert itself
      end 
      objects = {
        :vpn   => vpn,
        :certs => certs
      }
      format(
        :module   => 'openvpn',
        :path     => '/network/openvpn/client-side-configuration/howto',
        :format   => params[:format], 
        :formats  => %w{html rb} & @@formats, # exclude 'rb' in production
        :objects  => objects,
        :title    => 'Cient-side configuration: short guide'
      )   
    end

  end

end