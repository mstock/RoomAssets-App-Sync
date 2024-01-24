# RoomAssets-App-Sync

Simple application to synchronize assets from one or more [Pretalx][pretalx]
events to a local directory and (optionally) [Nextcloud][nextcloud]. This uses
public [Pretalx API resources][pretalx-api], so no login is required on the
[Pretalx][pretalx] side, and organizes the assets in a `<Room>/<Date>/<Session
start time>_-_<Session title>` structure.

The intention of this script is to run it on e.g. a server where it downloads
all the assets uploaded by the speakers of scheduled talks into this structure.
This structure is then synchronized to a folder in [Nextcloud][nextcloud],
which should then be synchronized to a shared presentation computer using [the
Nextcloud desktop client][nextcloud-client] at the conference venue. That way,
the assets automatically make it to the shared presentation computer without
any manual interaction by the organizers.


## Dependencies

The script has some non-core dependencies which can be installed on e.g. Debian
using a command like the following:

```perl
sudo apt install \
    libdatetime-format-iso8601-perl \
    libipc-system-simple-perl \
    libjson-perl \
    libmoose-perl \
    libmoosex-getopt-perl \
    libmoosex-types-path-class-perl \
    liburi-perl \
    libwww-perl
```

## Usage

A command like the following will download all the assets for the given rooms
for the given event and organizes them in the aforementioned structure:

```shell
./bin/room-assets-sync --pretalx-url https://pretalx.com --event <event identifier> \
    --target-dir <target directory> --room '<room name>' [--room '<another room name>']
```

For options related to [Nextcloud][nextcloud], see the output from `--help`.

Note that the script is currently basically 'silent' as long as there's no
error. If it seems like it's not doing anything, a potentially common mistake
is having used the wrong room name, so make sure its the same name as used in
[Pretalx][pretalx].


## License

This software is copyright (c) 2024 by Manfred Stock.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

[pretalx]: https://pretalx.com/
[pretalx-api]: https://docs.pretalx.org/api/fundamentals.html
[nextcloud]: https://nextcloud.com/
[nextcloud-client]: https://nextcloud.com/install/
