# irken-h2d.  needs Irken: an installed one (irken, on the PATH), or a
#  built irken-compiler tree:
#
#    $ make IRKEN_DIR=../irken-compiler
#
#  make             serve and serve-x402
#  make all         those, and acme, source, and the test programs
#  make test        the tests (python3, openssl, and a curl with HTTP/2)
#  make clean       remove what make builds
#
# photos/photos isn't here: it needs its FFI generated first (README.md).
# make doesn't know what the compiler's own files are: after updating
#  Irken, make clean (or make -B).
#
# (POSIX make: GNU make and BSD make both work.)

IRKEN_DIR =
IRKENFLAGS = -q

# with IRKEN_DIR, that tree's compiler, headers and library; otherwise
#  the installed irken.
IRKENC = sh -c 'if [ -n "$$0" ]; then d=`cd "$$0" && pwd` || exit 1; IRKENLIB="$$d/" CFLAGS="-O3 -I$$d/include" exec "$$d/self/irken" "$$@"; else exec irken "$$@"; fi' "$(IRKEN_DIR)" $(IRKENFLAGS)

SERVER = serve-main.scm server.scm handler.scm file-handler.scm login.scm \
         log.scm redirect.scm stats.scm timestamp.scm dns.scm
X402 = x402/hooks.scm x402/handler.scm x402/config.scm x402/settler.scm x402/x402.scm

SERVERS = serve serve-x402
TESTS = x402/t-x402 t-auth t-decode-timestamp t-lookup-month
OTHERS = acme/acme source/source

servers: $(SERVERS)

all: $(SERVERS) $(OTHERS) $(TESTS)

serve: serve.scm $(SERVER)
	@echo "irken serve.scm" && $(IRKENC) serve.scm

serve-x402: serve-x402.scm $(SERVER) $(X402)
	@echo "irken serve-x402.scm" && $(IRKENC) serve-x402.scm

acme/acme: acme/acme.scm
	@echo "irken acme/acme.scm" && $(IRKENC) acme/acme.scm

source/source: source/source.scm source/highlight.scm webutil.scm $(SERVER)
	@echo "irken source/source.scm" && $(IRKENC) source/source.scm

x402/t-x402: x402/t-x402.scm x402/x402.scm
	@echo "irken x402/t-x402.scm" && $(IRKENC) x402/t-x402.scm

t-auth: t-auth.scm
	@echo "irken t-auth.scm" && $(IRKENC) t-auth.scm

t-decode-timestamp: t-decode-timestamp.scm
	@echo "irken t-decode-timestamp.scm" && $(IRKENC) t-decode-timestamp.scm

t-lookup-month: t-lookup-month.scm
	@echo "irken t-lookup-month.scm" && $(IRKENC) t-lookup-month.scm

# t-x402 is compared with its ";; =>" lines; the other three print
#  what they print (see their sources for what to expect).  t-serve.py
#  checks plain serve, and test-e2e.py serve-x402.
test: $(SERVERS) $(TESTS)
	sed -n 's/^;; => \{0,1\}//p' x402/t-x402.scm > x402/t-x402.expected
	x402/t-x402 2>/dev/null > x402/t-x402.out
	diff x402/t-x402.expected x402/t-x402.out && echo "t-x402: as expected"
	./t-auth
	./t-decode-timestamp
	./t-lookup-month
	python3 t-serve.py ./serve
	python3 x402/test-e2e.py ./serve-x402

# only what's built here, by name: no wildcards near tracked files.
clean:
	for p in $(SERVERS) $(OTHERS) $(TESTS); do rm -f "$$p" "$$p.s" "$$p.c" "$$p.byc"; done
	rm -f x402/t-x402.expected x402/t-x402.out

.PHONY: servers all test clean
