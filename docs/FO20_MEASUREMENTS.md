# FO-20 operator measurement composition

`bin/af-measurements --wlo WLO.json [--rpof RPOF.json]` presents the public
owner-local measurement contracts without reading WLO execution files or RPOF
provider/budget files. Omitting `--rpof` leaves paid cost clearly unattached.

When the operator explicitly associates both contexts, estimated useful compute
is limited to intersections between WLO command intervals and RPOF tracked paid
resource intervals carrying the same generic worker and generation identity.
Unmatched or unaligned evidence remains visible as coverage and never becomes a
scheduling, scaling, admission, retry, deadline, or pricing decision.
