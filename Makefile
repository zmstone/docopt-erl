PROJECT = docopt
PROJECT_DESCRIPTION = Port of docopt for Erlang
PROJECT_VERSION = 0.1.0

EUNIT_OPTS = verbose
ERLC_OPTS = -Werror +warn_unused_vars +warn_shadow_vars +warn_unused_import +warn_obsolete_guard +debug_info

include erlang.mk

hex-publish: distclean
	$(verbose) rebar3 hex publish

