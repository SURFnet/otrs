# --
# Copyright (C) 2001-2018 OTRS AG, https://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::PostMaster::FollowUpCheck::IP;

use strict;
use warnings;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Ticket',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # Get communication log object.
    $Self->{CommunicationLogObject} = $Param{CommunicationLogObject} || die "Got no CommunicationLogObject!";

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $IP = $Param{GetParam}->{'X-OTRS-DynamicField-IP'} || '';

    if ( ! $IP ) {
        return;
    }

    $Self->{CommunicationLogObject}->ObjectLog(
        ObjectLogType => 'Message',
        Priority      => 'Debug',
        Key           => 'Kernel::System::PostMaster::FollowUpCheck::IP',
        Value         => "Searching for TicketNumber on IP $IP",
    );

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');

    my @TIDs = $TicketObject->TicketSearch(
        UserID => '1',
        Result => 'ARRAY',      
        StateType    => ['open', 'new', 'pending auto'],
        DynamicField_IP => {
                Equals => $IP,
        },
    );  

    return if !@TIDs;

    # Return the first found Ticket
    my $TicketID = $TIDs[0];

    if ($TicketID) {

        $Self->{CommunicationLogObject}->ObjectLog(
            ObjectLogType => 'Message',
            Priority      => 'Debug',
            Key           => 'Kernel::System::PostMaster::FollowUpCheck::IP',
            Value         => "Found valid TicketID '$TicketID' on IP $IP",
        );

        return $TicketID;
    }

    return;
}

1;

