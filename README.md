
 Irken HTTP/2 Server
=====================

An HTTPS (TLS 1.3, HTTP/2) file server, and an ACME client to keep its
certificate current, written in Irken.

To build
--------

Against an installed Irken (python3 util/install.py in the compiler
repo; set IRKENLIB if it isn't installed in /usr/local/lib/irken/):

    $ irken serve.scm
    $ irken acme/acme.scm

and install them as, e.g., /usr/local/sbin/irken-h2d and
/usr/local/bin/irken-acme.  These build against the installed copy of
Irken's libraries, so re-install Irken after changing them.

irken_h2d.sh is a FreeBSD rc script: see the comments at its top.

Privileges
----------

Start the server as root (it binds ports 80 and 443), with -user <name>
(irken_h2d_server_user in rc.conf): once the ports are bound and the log file
and certificates read, it becomes that user, with that user's groups
only, and there's no way back to root.  The certificate, key and users
file must then be readable by that user, for SIGHUP reloads.

Status page and logging
-----------------------

/status/ needs a login: a passkey (-passkeys <file>), or a password
(-users <file>, a file of "name:password" lines kept outside the repo,
mode 0600: the server warns otherwise).  With neither, /status/ is
disabled.  The photo and source browsers take the same options, for
the whole site.

Passkeys
--------

With -passkeys, a browser that isn't logged in is sent to /login/,
which logs in with a passkey (Touch ID, a phone, a security key...)
and sets a session cookie, good for a week.  Sessions are kept in
memory, so a restart logs everyone out.  With -users too, /login/ also
offers "use a password", and basic auth keeps working (for curl, say).

To add a passkey:

1. The server logs an enrollment link at startup and on each reload
   (SIGHUP): "to add a passkey (once, within the hour):
   https://<host>/login/enroll/<token>".  It works once, for an hour.
2. Open it on the host you'll use, give a name, and create the
   passkey.  The page shows a line like "sam <credential-id> <key>".
3. Add that line to the passkeys file, and reload the server
   (service irken_h2d reload).  Only now does the passkey work: the
   server never writes the file, so whoever can edit it decides who
   gets in, and a leaked enrollment link is no use by itself.

The passkeys file holds only public keys, so it needn't be secret, but
it must not be writable by the server's user: e.g. root:wheel 0644.
Delete a line (and reload) to revoke that passkey.

A passkey belongs to the site's domain, taken as the host's last two
labels (nightmare.com for dark.nightmare.com and www.nightmare.com),
so one passkey works on all of a domain's hosts, but another domain
(unintuitive.org) needs its own.  Passkeys can be ES256 or Ed25519.

Under daemon(8), the server's output goes to syslog.  It logs only
startup, SIGHUP reloads and errors, as plain lines; -d adds the
(colorful) per-connection debugging output.

The access log (-log, default /var/log/irken-httpd.log) is written by
the server itself, so to rotate it newsyslog renames it and sends
SIGHUP, and the server reopens it.  Since the server is no longer root
by then, newsyslog must create the new file owned by the server's
user.  In /etc/newsyslog.conf.d/irken-h2d.conf (daily at midnight,
keep 7, bzip2'd):

    /var/log/irken-httpd.log  www:www  644  7  *  @T00  JC  /var/run/irken_h2d.child.pid

(the child pid file is the server's own pid; /var/run/irken_h2d.pid is
daemon(8)'s, and daemon doesn't pass SIGHUP on.)  If the server can't
reopen the log, it logs why and keeps writing to the old file.

x402 payments
-------------

serve-x402 is serve with x402 payments: with -x402 <file>, it charges
for priced paths (HTTP 402 Payment Required, paid in e.g. USDC),
verified and settled by a facilitator.  Logged-in users (-users,
-passkeys) don't pay.  serve and serve-x402 are the same server
(serve-main.scm); serve has none of the x402 code.  See x402/README.md.

Certificates
------------

irken-acme gets certificates from Let's Encrypt with http-01
challenges, which the server answers on port 80 (-acme /var/acme), so
it can renew while the server runs.  Daily from cron:

    /usr/local/bin/irken-acme -challenges /var/acme -days 30 \
        -account /usr/local/etc/ssl/dark/acme-account.key \
        -key /usr/local/etc/ssl/dark/dark.key \
        -cert /usr/local/etc/ssl/dark/dark.chain \
        nightmare.com dark.nightmare.com www.nightmare.com unintuitive.org \
      | grep -q '^wrote' && service irken_h2d reload

[ this probably needs to be changed to use `cert-deploy` ]

irken-acme prints "wrote <cert>" only when it renews; "service
irken_h2d reload" sends the server SIGHUP, which reloads its
certificate and key.  See acme/README.txt.

Photo browser
-------------

photos/photos.scm is a second server built on the same parts
(server.scm): it browses a directory tree of photos.  Thumbnails come
straight out of the files (a JPEG's EXIF thumbnail, a HEIC's thumbnail
item), so there's nothing to index and nothing to wait for; a viewer
shows the full images, with a slideshow.

It needs libjpeg (libjpeg-turbo: `pkg install libjpeg-turbo`), for
JPEGs with no EXIF thumbnail.  Generate its interface once (and again
after changing photos/jpegthumb.h), from the top of this tree:

    $ IRKENLIB=<irken tree> <irken tree>/ffi/gen/genffi -gen ffi/jpegthumb.ffi
    $ irken photos/photos.scm
    $ photos/photos 0.0.0.0:8444 -root /photos -users photo-users \
        -cert ... -key ... -cache /var/cache/irken-photos

-users is the same name:password file as for /status/, and then
everything (including /status/) needs a login; -open serves without
one, for a private network only.  One or the other is required.

JPEGs with no EXIF thumbnail (scans, mostly) are decoded at 1/8 scale
(or 1/4, 1/2) by libjpeg, through a small C shim (photos/jpegthumb.c).
The decode is done a chunk of the file at a time, with libjpeg's I/O
suspension, and other connections get their turn in between, so a
directory of big scans doesn't hold the server up.  With -cache, the
results are kept.

Raw files that are TIFF inside (NEF, ARW, CR2, DNG) are shown by the
JPEG previews the camera put in them (photos/raw.scm): the smallest
that's the right shape as the thumbnail (scaled, if it's big: a NEF's
is full-size), and the biggest in the viewer.  The raw data itself is
never sent.  (Not yet: CR3, which is ISOBMFF like HEIC; ORF, RW2.)

Browsers other than Safari can't show HEIC: with -cache <dir>, HEIC
thumbnails and images are converted to JPEG with libheif's heif-dec
(-heif-dec <command>; called as `<command> -q 85 in.heic out.jpg`), and
the results kept in <dir>, which can be emptied at any time.  Without
-cache, HEICs are sent as they are.

The links at the top right, and [ and ], go to the directories before
and after this one.  In the viewer: arrows (or click/swipe) move, space
starts and stops the slideshow, i shows the date, camera and size, f is
full screen, the globe (or m) shows a photo with a location on Google
Maps, and escape goes back to the thumbnails.  The URL's #name links to
an image.

JPEGs whose pixels were rotated by a tool that left the EXIF orientation
alone (the frame is the other way round from PixelX/YDimension) are
sent with the orientation set to 1, so that browsers don't turn them a
second time.

Source browser
--------------

source/source.scm, built on the same parts, browses a tree of Irken
source: directory listings, and files with line numbers (#L<n> links
to a line).  Irken files (.scm) are highlighted the way irken.el does
it (source/highlight.scm): keywords, the names being defined,
constructors, ->, comments, strings, characters, numbers.  Each
top-level definition has an anchor, and the uses of its name in the
file link to it; the file's definitions are listed at the top.
(require "...") links to the file, looked for in the directories above
the file's (the compiler resolves requires from where it's run, usually
the top of the project), and then in the -lib directories.  Other text
files are shown as they are; /r/<file> is the file itself.

    $ irken source/source.scm
    $ source/source 0.0.0.0:8445 -root ~/src/irken -lib claude/irken-compiler -open

-users and -open are as for the photo browser.

