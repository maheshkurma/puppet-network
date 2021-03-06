# == Class: network
#
# This module manages Red Hat/Fedora network configuration.
#
# === Parameters:
#
# None
#
# === Actions:
#
# Defines the network service so that other resources can notify it to restart.
#
# === Sample Usage:
#
#   include '::network'
#
# === Authors:
#
# Mike Arnold <mike@razorsedge.org>
#
# === Copyright:
#
# Copyright (C) 2011 Mike Arnold, unless otherwise noted.
#
class network {
  # Only run on RedHat/CentOS and SLES derived systems.
  case $::osfamily {
    'RedHat': { }
    'Suse': {
      case $::operatingsystemrelease {
        /^(11|12)/: { }
        default: {
          fail("This network module only supports SLES 11 and 12 systems. The current machine uses ${$::operatingsystemrelease}")
        }
      }
    }
    default: {
      fail("This network module only supports RedHat and Suse based systems. Current machine OS family is ${$::osfamily}")
    }
  }

  # Disable NetworkManager - otherwise it may cause issues with default gateway and other routing rules
  service { 'NetworkManager':
    ensure     => 'stopped',
    enable     => false
  }

  clean_ifcfg { 'clean_if_configs':
    before => Service['network'],
  }

  # We use a custom service provider defined in this module for rhel/centos7 to eliminate an issue with "orphaned" dhclients
    service { 'network':
      ensure     => 'running',
      enable     => true,
      hasrestart => true,
      hasstatus  => true,
      provider   => $::operatingsystemmajrelease ? {
        "7"     => "systemd_network",
        default => undef
      }
    }

} # class network

# == Definition: network_if_base
#
# This definition is private, i.e. it is not intended to be called directly
# by users.  It can be used to write out the following device files:
#  /etc/sysconfig/networking-scripts/ifcfg-eth
#  /etc/sysconfig/networking-scripts/ifcfg-eth:alias
#  /etc/sysconfig/networking-scripts/ifcfg-bond(master)
#
# === Parameters:
#
#   $ensure          - required - up|down
#   $ipaddress       - required
#   $netmask         - required
#   $macaddress      - required
#   $gateway         - optional
#   $bootproto       - optional
#   $userctl         - optional - defaults to false
#   $mtu             - optional
#   $dhcp_hostname   - optional
#   $ethtool_opts    - optional
#   $bonding_opts    - optional
#   $isalias         - optional
#   $peerdns         - optional
#   $dns1            - optional
#   $dns2            - optional
#   $domain          - optional
#   $bridge          - optional
#   $scope           - optional
#   $linkdelay       - optional
#   $check_link_down - optional
#
# === Actions:
#
# Performs 'service network restart' after any changes to the ifcfg file.
# Turns off the NetworkManager since the network config will be managed through puppet only.
#
# === TODO:
#
#   METRIC=
#   HOTPLUG=yes|no
#   WINDOW=
#   SRCADDR=
#   NOZEROCONF=yes
#   PERSISTENT_DHCLIENT=yes|no|1|0
#   DHCPRELEASE=yes|no|1|0
#   DHCLIENT_IGNORE_GATEWAY=yes|no|1|0
#   REORDER_HDR=yes|no
#
# === Authors:
#
# Mike Arnold <mike@razorsedge.org>
#
# === Copyright:
#
# Copyright (C) 2011 Mike Arnold, unless otherwise noted.
#
define network_if_base (
  $ensure,
  $ipaddress       = undef,
  $netmask         = undef,
  $macaddress      = undef,
  $vlanId          = undef,
  $gateway         = undef,
  $ipv6address     = undef,
  $ipv6gateway     = undef,
  $ipv6init        = false,
  $ipv6autoconf    = false,
  $bootproto       = 'none',
  $userctl         = false,
  $mtu             = undef,
  $dhcp_hostname   = undef,
  $ethtool_opts    = undef,
  $bonding_opts    = undef,
  $isalias         = false,
  $isethernet      = true,
  $peerdns         = false,
  $ipv6peerdns     = false,
  $dns1            = undef,
  $dns2            = undef,
  $domain          = undef,
  $bridge          = undef,
  $linkdelay       = undef,
  $scope           = undef,
  $linkdelay       = undef,
  $check_link_down = false,
  $defroute        = undef,
  $type            = undef,
) {
  # Validate our booleans
  validate_bool($userctl)
  validate_bool($isalias)
  validate_bool($peerdns)
  validate_bool($ipv6init)
  validate_bool($ipv6autoconf)
  validate_bool($ipv6peerdns)
  validate_bool($check_link_down)

  # Validate our regular expressions
  $states = [ '^up$', '^down$' ]
  validate_re($ensure, $states, '$ensure must be either "up" or "down".')

  include '::network'

  # ASM: For baremetal server, the name is the mac address of the port or partition.
  #      For VM deployment, the name is always the sequence of the network interface.
  if (type($name) == "integer") {
    $interface = get_seq_interface($name)
  } elsif is_mac_address($name) {
    $interface = map_macaddr_to_interface($name)
    if !$interface {
      fail('Could not find the interface name for the given macaddress...')
    }
  } else {
    $interface = $name
  }

  # Deal with the case where $dns2 is non-empty and $dns1 is empty.
  if $dns2 {
    if !$dns1 {
      $dns1_real = $dns2
      $dns2_real = undef
    } else {
      $dns1_real = $dns1
      $dns2_real = $dns2
    }
  } else {
    $dns1_real = $dns1
    $dns2_real = $dns2
  }

  if $isalias {
    $onparent = $ensure ? {
      'up'    => 'yes',
      'down'  => 'no',
      default => undef,
    }
    $iftemplate = template('network/ifcfg-alias.erb')
  } else {
    $onboot = $ensure ? {
      'up'    => 'yes',
      'down'  => 'no',
      default => undef,
    }
    $iftemplate = template('network/ifcfg-eth.erb')
  }

  $ifcfg_filepath = ifcfg_filepath($::osfamily)

  if $vlanId {
    file { "ifcfg-${interface}.${vlanId}":
      ensure  => 'present',
      mode    => '0644',
      owner   => 'root',
      group   => 'root',
      path    => "${ifcfg_filepath}ifcfg-${interface}.${vlanId}",
      content => $iftemplate,
      notify => Service['network'],
    }
  } else {
    file { "ifcfg-${interface}":
      ensure  => 'present',
      mode    => '0644',
      owner   => 'root',
      group   => 'root',
      path    => "${ifcfg_filepath}ifcfg-${interface}",
      content => $iftemplate,
      notify => Service['network'],
    }
  }
} # define network_if_base
