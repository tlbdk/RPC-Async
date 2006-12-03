
my %commands = (
    'snmpget' => {
        request => [
            qr/^(v1|v2|v2c)$/, "version",
            qr/^($REGEXP_IP)$/, "ip",
            qr/^((?:(?:\\\s)|[^\s])+)$/, "community",
            qr/^\.?(\d{1,10}(?:\.\d{1,10})*)$/, "oid",
        ],
        response => [
            qr/^(.*)$/s, "data"
        ]

    },
);



