# --
# Copyright (C) 2001-2018 OTRS AG, https://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::CustomerCompany::DB2;

use strict;
use warnings;
use Data::Dumper;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::System::Cache',
    'Kernel::System::DB',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Log',
    'Kernel::System::Valid',
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    # get customer company map
    $Self->{CustomerCompanyMap} = $Param{CustomerCompanyMap} || die "Got no CustomerCompanyMap!";

    # config options
    $Self->{CustomerCompanyTable} = $Self->{CustomerCompanyMap}->{Params}->{Table}
        || die "Need CustomerCompany->Params->Table in Kernel/Config.pm!";
    $Self->{CustomerCompanyKey} = $Self->{CustomerCompanyMap}->{CustomerCompanyKey}
        || die "Need CustomerCompany->CustomerCompanyKey in Kernel/Config.pm!";
    $Self->{CustomerCompanyValid} = $Self->{CustomerCompanyMap}->{'CustomerCompanyValid'};
    $Self->{SearchListLimit}      = $Self->{CustomerCompanyMap}->{'CustomerCompanySearchListLimit'} || 50000;
    $Self->{SearchPrefix}         = $Self->{CustomerCompanyMap}->{'CustomerCompanySearchPrefix'};
    if ( !defined( $Self->{SearchPrefix} ) ) {
        $Self->{SearchPrefix} = '';
    }
    $Self->{SearchSuffix} = $Self->{CustomerCompanyMap}->{'CustomerCompanySearchSuffix'};
    if ( !defined( $Self->{SearchSuffix} ) ) {
        $Self->{SearchSuffix} = '*';
    }

    # create cache object, but only if CacheTTL is set in customer config
    if ( $Self->{CustomerCompanyMap}->{CacheTTL} ) {
        $Self->{CacheObject} = $Kernel::OM->Get('Kernel::System::Cache');
        $Self->{CacheType}   = 'CustomerCompany' . $Param{Count};
        $Self->{CacheTTL}    = $Self->{CustomerCompanyMap}->{CacheTTL} || 0;
    }

    # get database object
    $Self->{DBObject} = $Kernel::OM->Get('Kernel::System::DB');

    # create new db connect if DSN is given
    if ( $Self->{CustomerCompanyMap}->{Params}->{DSN} ) {
        $Self->{DBObject} = Kernel::System::DB->new(
            DatabaseDSN  => $Self->{CustomerCompanyMap}->{Params}->{DSN},
            DatabaseUser => $Self->{CustomerCompanyMap}->{Params}->{User},
            DatabasePw   => $Self->{CustomerCompanyMap}->{Params}->{Password},
            Type         => $Self->{CustomerCompanyMap}->{Params}->{Type} || '',
        ) || die('Can\'t connect to database!');

        # remember that we have the DBObject not from parent call
        $Self->{NotParentDBObject} = 1;
    }

    # this setting specifies if the table has the create_time,
    # create_by, change_time and change_by fields of OTRS
    $Self->{ForeignDB} = $Self->{CustomerCompanyMap}->{Params}->{ForeignDB} ? 1 : 0;

    # defines if the database search will be performend case sensitive (1) or not (0)
    $Self->{CaseSensitive} = $Self->{CustomerCompanyMap}->{Params}->{SearchCaseSensitive}
        // $Self->{CustomerCompanyMap}->{Params}->{CaseSensitive} || 0;

    # fetch names of configured dynamic fields
    my @DynamicFieldMapEntries = grep { $_->[5] eq 'dynamic_field' } @{ $Self->{CustomerCompanyMap}->{Map} };
    $Self->{ConfiguredDynamicFieldNames} = { map { $_->[2] => 1 } @DynamicFieldMapEntries };

    return $Self;
}

sub CustomerCompanyList {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    my $Limit = $Param{Limit} // $Self->{SearchListLimit};

    my $CacheType;
    my $CacheKey;

    # check cache
    if ( $Self->{CacheObject} ) {

        $CacheType = $Self->{CacheType} . '_CustomerCompanyList';
        $CacheKey  = "CustomerCompanyList::${Limit}::" . ( $Param{Search} || '' );

        my $Data = $Self->{CacheObject}->Get(
            Type => $CacheType,
            Key  => $CacheKey,
        );
        return %{$Data} if ref $Data eq 'HASH';
    }

    # add valid option if required
    my $SQL;
    my $Search = $Param{Search} // "" =~ s/\*/%/r;

    # sql
    my $CompleteSQL = "SELECT customerid, description, prefix, doelgroepcode, organisatiecode FROM customers WHERE";

    # Search in prefix if search looks like IP
    if ( $Search =~ /(\d{1,3}\.){3}\d{1,3}/ or $Search =~ /([A-f0-9:]+:+)+[A-f0-9]+/ ) {
        $CompleteSQL .= " ? << prefix";
    } else {
        $CompleteSQL .= " LOWER(description) LIKE LOWER(?)";
        $Search = "%$Search%";
    }
    
    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message => "CustomerCompany SQL: $CompleteSQL",
    );

    # get data from customer company table
    $Self->{DBObject}->Prepare(
        SQL   => $CompleteSQL,
        Bind => [\"$Search"],
    );

    my @CustomerCompanyData;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        push @CustomerCompanyData, [@Row];
    }

    my %List;

    CUSTOMERCOMPANYDATA:
    for my $CustomerCompanyData (@CustomerCompanyData) {
        my $CustomerCompanyID = shift @{$CustomerCompanyData};
        next CUSTOMERCOMPANYDATA if $List{$CustomerCompanyID};
        last if !$Limit--;
        $List{$CustomerCompanyID} = shift @{$CustomerCompanyData};
    }

    # cache request
    if ( $Self->{CacheObject} ) {
        $Self->{CacheObject}->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => \%List,
            TTL   => $Self->{CacheTTL},
        );
    }

    return %List;
}

sub CustomerCompanySearchDetail {
    my ( $Self, %Param ) = @_;

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'error',
        Message  => "CustomerCompanySearchDetail entry, Searchfields:" . Dumper(\$Param{SearchFields}),
    );

    if ( ref $Param{SearchFields} ne 'ARRAY' ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "SearchFields must be an array reference!",
        );
        return;
    }

    my $Valid = defined $Param{Valid} ? $Param{Valid} : 1;

    $Param{Limit} //= '';

    # Split the search fields in scalar and array fields.
    my @ScalarSearchFields = grep { 'Input' eq $_->{Type} } @{ $Param{SearchFields} };
    my @ArraySearchFields  = grep { 'Selection' eq $_->{Type} } @{ $Param{SearchFields} };

    # Verify that all passed array parameters contain an arrayref.
    ARGUMENT:
    for my $Argument (@ArraySearchFields) {
        if ( !defined $Param{ $Argument->{Name} } ) {
            $Param{ $Argument->{Name} } ||= [];

            next ARGUMENT;
        }

        if ( ref $Param{ $Argument->{Name} } ne 'ARRAY' ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "$Argument->{Name} must be an array reference!",
            );
            return;
        }
    }

    # Set the default behaviour for the return type.
    my $Result = $Param{Result} || 'ARRAY';

    # Handle the diffrent result types.
    if ( $Result eq 'COUNT' ) {
        return 0;
    }
    else {
        return \();
    }
=pod
    # Special handling if the result type is 'COUNT'.
    if ( $Result eq 'COUNT' ) {

        # Ignore the parameter 'Limit' when result type is 'COUNT'.
        $Param{Limit} = '';

        # Delete the OrderBy parameter when the result type is 'COUNT'.
        $Param{OrderBy} = [];
    }

    # Define order table from the search fields.
    my %OrderByTable = map { $_->{Name} => $_->{DatabaseField} } @{ $Param{SearchFields} };

    for my $Field (@ArraySearchFields) {

        my $SelectionsData = $Field->{SelectionsData};

        for my $SelectedValue ( @{ $Param{ $Field->{Name} } } ) {

            # Check if the selected value for the current field is valid.
            if ( !$SelectionsData->{$SelectedValue} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "The selected value $Field->{Name} is not valid!",
                );
                return;
            }
        }
    }

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # Assemble the conditions used in the WHERE clause.
    my @SQLWhere;

    for my $Field (@ScalarSearchFields) {

        # Search for scalar fields (wildcards are allowed).
        if ( $Param{ $Field->{Name} } ) {

            # Get like escape string needed for some databases (e.g. oracle).
            my $LikeEscapeString = $DBObject->GetDatabaseFunction('LikeEscapeString');

            $Param{ $Field->{Name} } = $DBObject->Quote( $Param{ $Field->{Name} }, 'Like' );

            $Param{ $Field->{Name} } =~ s{ \*+ }{%}xmsg;

            # If the field contains more than only '%'.
            if ( $Param{ $Field->{Name} } !~ m{ \A %* \z }xms ) {
                push @SQLWhere,
                    "LOWER($Field->{DatabaseField}) LIKE LOWER('$Param{ $Field->{Name} }') $LikeEscapeString";
            }
        }
    }

    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

    # Check all configured change dynamic fields, build lookup hash by name.
    my %CustomerCompanyDynamicFieldName2Config;
    my $CustomerCompanyDynamicFields = $DynamicFieldObject->DynamicFieldListGet(
        ObjectType => 'CustomerCompany',
    );
    for my $DynamicField ( @{$CustomerCompanyDynamicFields} ) {
        $CustomerCompanyDynamicFieldName2Config{ $DynamicField->{Name} } = $DynamicField;
    }

    my $SQLDynamicFieldFrom     = '';
    my $SQLDynamicFieldWhere    = '';
    my $DynamicFieldJoinCounter = 1;

    DYNAMICFIELD:
    for my $DynamicField ( @{$CustomerCompanyDynamicFields} ) {

        my $SearchParam = $Param{ "DynamicField_" . $DynamicField->{Name} };

        next DYNAMICFIELD if ( !$SearchParam );
        next DYNAMICFIELD if ( ref $SearchParam ne 'HASH' );

        my $NeedJoin;

        for my $Operator ( sort keys %{$SearchParam} ) {

            my @SearchParams = ( ref $SearchParam->{$Operator} eq 'ARRAY' )
                ? @{ $SearchParam->{$Operator} }
                : ( $SearchParam->{$Operator} );

            my $SQLDynamicFieldWhereSub = '';
            if ($SQLDynamicFieldWhere) {
                $SQLDynamicFieldWhereSub = ' AND (';
            }
            else {
                $SQLDynamicFieldWhereSub = ' (';
            }

            my $Counter = 0;
            TEXT:
            for my $Text (@SearchParams) {
                next TEXT if ( !defined $Text || $Text eq '' );

                $Text =~ s/\*/%/gi;

                # Check search attribute, we do not need to search for '*'.
                next TEXT if $Text =~ /^\%{1,3}$/;

                my $ValidateSuccess = $DynamicFieldBackendObject->ValueValidate(
                    DynamicFieldConfig => $DynamicField,
                    Value              => $Text,
                    UserID             => $Param{UserID} || 1,
                );
                if ( !$ValidateSuccess ) {
                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => "Search not executed due to invalid value '"
                            . $Text
                            . "' on field '"
                            . $DynamicField->{Name} . "'!",
                    );
                    return;
                }

                if ($Counter) {
                    $SQLDynamicFieldWhereSub .= ' OR ';
                }
                $SQLDynamicFieldWhereSub .= $DynamicFieldBackendObject->SearchSQLGet(
                    DynamicFieldConfig => $DynamicField,
                    TableAlias         => "dfv$DynamicFieldJoinCounter",
                    Operator           => $Operator,
                    SearchTerm         => $Text,
                );

                $Counter++;
            }
            $SQLDynamicFieldWhereSub .= ') ';

            if ($Counter) {
                $SQLDynamicFieldWhere .= $SQLDynamicFieldWhereSub;
                $NeedJoin = 1;
            }
        }

        if ($NeedJoin) {
            $SQLDynamicFieldFrom .= "
                INNER JOIN dynamic_field_value dfv$DynamicFieldJoinCounter
                    ON (df_obj_id_name.object_id = dfv$DynamicFieldJoinCounter.object_id
                        AND dfv$DynamicFieldJoinCounter.field_id = "
                . $DBObject->Quote( $DynamicField->{ID}, 'Integer' ) . ")
            ";

            $DynamicFieldJoinCounter++;
        }
    }

    # Execute a dynamic field search, if a dynamic field where statement exists.
    if ( $SQLDynamicFieldFrom && $SQLDynamicFieldWhere ) {

        my @DynamicFieldCustomerIDs;

        # Sql uery for the dynamic fields.
        my $SQLDynamicField
            = "SELECT DISTINCT(df_obj_id_name.object_name) FROM dynamic_field_obj_id_name df_obj_id_name "
            . $SQLDynamicFieldFrom
            . " WHERE "
            . $SQLDynamicFieldWhere;

        my $UsedCache;

        if ( $Self->{CacheObject} ) {

            my $DynamicFieldSearchCacheData = $Self->{CacheObject}->Get(
                Type => $Self->{CacheType} . '_CustomerSearchDetailDynamicFields',
                Key  => $SQLDynamicField,
            );

            if ( defined $DynamicFieldSearchCacheData ) {
                if ( ref $DynamicFieldSearchCacheData eq 'ARRAY' ) {
                    @DynamicFieldCustomerIDs = @{$DynamicFieldSearchCacheData};

                    # Set the used cache flag.
                    $UsedCache = 1;
                }
                else {
                    $Kernel::OM->Get('Kernel::System::Log')->Log(
                        Priority => 'error',
                        Message  => 'Invalid ref ' . ref($DynamicFieldSearchCacheData) . '!'
                    );
                    return;
                }
            }
        }

        # Get the data only from database, if no cache entry exists.
        if ( !$UsedCache ) {

            return if !$DBObject->Prepare(
                SQL => $SQLDynamicField,
            );

            while ( my @Row = $DBObject->FetchrowArray() ) {
                push @DynamicFieldCustomerIDs, $Row[0];
            }

            if ( $Self->{CacheObject} ) {
                $Self->{CacheObject}->Set(
                    Type  => $Self->{CacheType} . '_CustomerSearchDetailDynamicFields',
                    Key   => $SQLDynamicField,
                    Value => \@DynamicFieldCustomerIDs,
                    TTL   => $Self->{CustomerCompanyMap}->{CacheTTL},
                );
            }
        }

        # Add the user logins from the dynamic fields, if a search result exists from the dynamic field search
        #   or skip the search and return a emptry array ref (or zero for the result 'COUNT', if no user logins exists
        #   from the dynamic field search.
        if (@DynamicFieldCustomerIDs) {

            my $SQLQueryInCondition = $Kernel::OM->Get('Kernel::System::DB')->QueryInCondition(
                Key      => $Self->{CustomerCompanyKey},
                Values   => \@DynamicFieldCustomerIDs,
                BindMode => 0,
            );

            push @SQLWhere, $SQLQueryInCondition;
        }
        else {
            return $Result eq 'COUNT' ? 0 : [];
        }
    }

    FIELD:
    for my $Field (@ArraySearchFields) {

        next FIELD if !@{ $Param{ $Field->{Name} } };

        my $SQLQueryInCondition = $Kernel::OM->Get('Kernel::System::DB')->QueryInCondition(
            Key      => $Field->{DatabaseField},
            Values   => $Param{ $Field->{Name} },
            BindMode => 0,
        );

        push @SQLWhere, $SQLQueryInCondition;
    }

    # Add the valid option if needed.
    if ( $Self->{CustomerCompanyMap}->{CustomerValid} && $Valid ) {

        my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');

        push @SQLWhere,
            "$Self->{CustomerCompanyMap}->{CustomerValid} IN (" . join( ', ', $ValidObject->ValidIDsGet() ) . ") ";
    }

    # Check if OrderBy contains only unique valid values.
    my %OrderBySeen;
    for my $OrderBy ( @{ $Param{OrderBy} } ) {

        if ( !$OrderBy || $OrderBySeen{$OrderBy} ) {

            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "OrderBy contains invalid value '$OrderBy' "
                    . 'or the value is used more than once!',
            );
            return;
        }

        # Remember the value to check if it appears more than once.
        $OrderBySeen{$OrderBy} = 1;
    }

    # Check if OrderByDirection array contains only 'Up' or 'Down'.
    DIRECTION:
    for my $Direction ( @{ $Param{OrderByDirection} } ) {

        # Only 'Up' or 'Down' allowed.
        next DIRECTION if $Direction eq 'Up';
        next DIRECTION if $Direction eq 'Down';

        # found an error
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "OrderByDirection can only contain 'Up' or 'Down'!",
        );
        return;
    }

    # Build the sql statement for the search.
    my $SQL = "SELECT DISTINCT($Self->{CustomerCompanyKey})";

    # Modify SQL when the result type is 'COUNT'.
    if ( $Result eq 'COUNT' ) {
        $SQL = "SELECT COUNT(DISTINCT($Self->{CustomerCompanyKey}))";
    }

    my @SQLOrderBy;

    # The Order by clause is not needed for the result type 'COUNT'.
    if ( $Result ne 'COUNT' ) {

        my $Count = 0;

        ORDERBY:
        for my $OrderBy ( @{ $Param{OrderBy} } ) {

            # Set the default order direction.
            my $Direction = 'DESC';

            # Add the given order direction.
            if ( $Param{OrderByDirection}->[$Count] ) {
                if ( $Param{OrderByDirection}->[$Count] eq 'Up' ) {
                    $Direction = 'ASC';
                }
                elsif ( $Param{OrderByDirection}->[$Count] eq 'Down' ) {
                    $Direction = 'DESC';
                }
            }

            $Count++;

            next ORDERBY if !$OrderByTable{$OrderBy};

            push @SQLOrderBy, "$OrderByTable{$OrderBy} $Direction";

            next ORDERBY if $OrderBy eq 'CustomerID';

            $SQL .= ", $OrderByTable{$OrderBy}";
        }

        # If there is a possibility that the ordering is not determined
        #   we add an descending ordering by id.
        if ( !grep { $_ eq 'CustomerID' } ( @{ $Param{OrderBy} } ) ) {
            push @SQLOrderBy, "$Self->{CustomerCompanyKey} DESC";
        }
    }

    # Add form to the SQL after the order by creation.
    $SQL .= " FROM $Self->{CustomerCompanyTable} ";

    if (@SQLWhere) {
        my $SQLWhereString = join ' AND ', map {"( $_ )"} @SQLWhere;
        $SQL .= "WHERE $SQLWhereString ";
    }

    if (@SQLOrderBy) {
        my $OrderByString = join ', ', @SQLOrderBy;
        $SQL .= "ORDER BY $OrderByString";
    }

    # Check if a cache exists before we ask the database.
    if ( $Self->{CacheObject} ) {

        my $CacheData = $Kernel::OM->Get('Kernel::System::Cache')->Get(
            Type => $Self->{CacheType} . '_CustomerCompanySearchDetail',
            Key  => $SQL . $Param{Limit},
        );

        if ( defined $CacheData ) {
            if ( ref $CacheData eq 'ARRAY' ) {
                return $CacheData;
            }
            elsif ( ref $CacheData eq '' ) {
                return $CacheData;
            }
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'Invalid ref ' . ref($CacheData) . '!'
            );
            return;
        }
    }

    return if !$DBObject->Prepare(
        SQL   => $SQL,
        Limit => $Param{Limit},
    );

    my @IDs;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        push @IDs, $Row[0];
    }

    # Handle the diffrent result types.
    if ( $Result eq 'COUNT' ) {

        if ( $Self->{CacheObject} ) {
            $Kernel::OM->Get('Kernel::System::Cache')->Set(
                Type  => $Self->{CacheType} . '_CustomerCompanySearchDetail',
                Key   => $SQL . $Param{Limit},
                Value => $IDs[0],
                TTL   => $Self->{CacheTTL},
            );
        }

        return $IDs[0];
    }

    else {

        if ( $Self->{CacheObject} ) {
            $Kernel::OM->Get('Kernel::System::Cache')->Set(
                Type  => $Self->{CacheType} . '_CustomerCompanySearchDetail',
                Key   => $SQL . $Param{Limit},
                Value => \@IDs,
                TTL   => $Self->{CacheTTL},
            );
        }

        return \@IDs;
    }
=cut
}

sub CustomerCompanyGet {
    my ( $Self, %Param ) = @_;
    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'debug',
        Message => "CustomerCompanyGet CustomerID: $Param{CustomerID}",
    );

    # check needed stuff
    if ( !$Param{CustomerID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need CustomerID!'
        );
        return;
    }

    # check cache
    if ( $Self->{CacheObject} ) {
        my $Data = $Self->{CacheObject}->Get(
            Type => $Self->{CacheType},
            Key  => "CustomerCompanyGet::$Param{CustomerID}",
        );
        return %{$Data} if ref $Data eq 'HASH';
    }

    my $SQL = "SELECT description, prefix, doelgroepcode, organisatiecode FROM customers WHERE customerid=?";

    # get initial data
    return if !$Self->{DBObject}->Prepare(
        SQL  => $SQL,
        Bind => [ \$Param{CustomerID} ]
    );

    # fetch the result
    my %Data;
    $Data{'CustomerID'} = $Param{CustomerID};
    my $CustomerCompanyName;
    my @CustomerCompanyPrefix;
    my $CustomerCompanyDGC;
    my $CustomerCompanyOrg;
    while ( my @Row = $Self->{DBObject}->FetchrowArray() ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'debug',
            Message => "Row: " . Dumper(\@Row),
        );
        $CustomerCompanyName = $Row[0];
        push @CustomerCompanyPrefix, $Row[1];
        $CustomerCompanyDGC = $Row[2];
        $CustomerCompanyOrg = $Row[3];
    }
    $Data{'CustomerCompanyName'} = $CustomerCompanyName;
    $Data{'CustomerCompanyDGC'} = $CustomerCompanyDGC;
    $Data{'CustomerCompanyOrg'} = $CustomerCompanyOrg;
    $Data{'CustomerCompanyPrefix'} = join("; ", @CustomerCompanyPrefix);

    # cache request
    if ( $Self->{CacheObject} ) {
        $Self->{CacheObject}->Set(
            Type  => $Self->{CacheType},
            Key   => "CustomerCompanyGet::$Param{CustomerID}",
            Value => \%Data,
            TTL   => $Self->{CacheTTL},
        );
    }

    # return data
    return (%Data);
}

sub CustomerCompanyAdd {
    return 1;
}

sub CustomerCompanyUpdate {
    return 1;
}

sub _CustomerCompanyCacheClear {
    my ( $Self, %Param ) = @_;

    return if !$Self->{CacheObject};

    if ( !$Param{CustomerID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Need CustomerID!'
        );
        return;
    }

    $Self->{CacheObject}->Delete(
        Type => $Self->{CacheType},
        Key  => "CustomerCompanyGet::$Param{CustomerID}",
    );

    # delete all search cache entries
    $Self->{CacheObject}->CleanUp(
        Type => $Self->{CacheType} . '_CustomerCompanyList',
    );

    for my $Function (qw(CustomerCompanyList)) {
        for my $Valid ( 0 .. 1 ) {
            $Self->{CacheObject}->Delete(
                Type => $Self->{CacheType},
                Key  => "${Function}::${Valid}",
            );
        }
    }

    return 1;
}

sub DESTROY {
    my $Self = shift;

    # disconnect if it's not a parent DBObject
    if ( $Self->{NotParentDBObject} ) {
        if ( $Self->{DBObject} ) {
            $Self->{DBObject}->Disconnect();
        }
    }

    return 1;
}

1;

