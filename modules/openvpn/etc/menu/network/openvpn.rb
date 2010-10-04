class OnBoard
  MENU_ROOT.add_path('/network/openvpn', {
    :href => '/network/openvpn',
    :children => %r{^/network/openvpn/vpn/.+},
    :name => 'OpenVPN',
    :desc => 'Virtual Private Networks',
    :n    => 2
  })
  MENU_ROOT.add_path('/network/openvpn/client-side-configuration', {
    :href => '/network/openvpn/client-side-configuration',
    #:children => %r{^/network/openvpn/vpn/.+},
    :name => 'Client-side configuration Wizard',
    :desc => 'This will also help you to configure Windows clients',
    #:n    => 2
  })
end


