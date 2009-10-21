#!/usr/bin/env perl 
use strict;
use warnings;
use Carp;

use Net::DBus;

my $bus = Net::DBus->find;

# ... or explicitly go for the session bus
my $bus = Net::DBus->session;

# .... or explicitly go for the system bus
my $bus = Net::DBus->system

# Get a handle to the HAL service
my $hal = $bus->get_service("org.freedesktop.Hal");

# Get the device manager
my $manager = $hal->get_object("/org/freedesktop/Hal/Manager",
                               "org.freedesktop.Hal.Manager");

# List devices
foreach my $dev (@{$manager->GetAllDevices}) {
    print $dev, "\n";
}


######### Providing services ##############

# Register a service known as 'org.example.Jukebox'
my $service = $bus->export_service("org.example.Jukebox");
