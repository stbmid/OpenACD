#!/usr/bin/env bash

BASEDIR="$( cd "$( dirname "$0" )" && pwd)"
REBAR="$BASEDIR/rebar"

function pre_compile {
	ebinDir="$BASEDIR/ebin"

	if [ ! -d "$ebinDir" ]; then
		mkdir "$ebinDir"
	fi
	
	# record what commit/version openacd is at
	OPENACD_COMMIT=""
	if [ -d "$BASEDIR/.git" ]
	then
		OPENACD_COMMIT=`git log -1 --pretty=format:%H`
	fi
	if [ -e "$BASEDIR/include/commit_ver.hrl" ] && [ ! $OPENACD_COMMIT ]
	then
	 exit 0
	else
		if [ ! $OPENACD_COMMIT ]
		then
			OPENACD_COMMIT="undefined"
		else
			OPENACD_COMMIT="\"$OPENACD_COMMIT\""
		fi
	fi
	echo "%% automatically generated by OpenACD precompile script.  Editing means
%% it will just get overwritten again.
	
-define(OPENACD_COMMIT, $OPENACD_COMMIT)." > "$BASEDIR"/include/commit_ver.hrl
}

function pre_get-deps {
	if [ "${GIT_UPDATE_DISABLED}" != "1" ]; then
		echo "Updating submodules..."
		cd "$BASEDIR"
		git submodule init && git submodule update
		cd -
	fi
}

function post_get-deps {
	# needed by rebar to be added to lib path
	mkdir -p "$BASEDIR/ebin"

	# create temp apps directory
	appsDir="$BASEDIR/apps"
	if [ ! -d "$appsDir" ]; then
		mkdir -p "$appsDir"
		includeApps=./include_apps/*
		for app in $includeApps; do
			ln -sf ../"$app" "$appsDir"
		done

		oaDir="$appsDir"/OpenACD
		mkdir "$oaDir"
		ln -sf ../../ebin "$oaDir"/ebin
		ln -sf ../../src "$oaDir"/src
		ln -sf ../../include "$oaDir"/include
		ln -sf ../../priv "$oaDir"/priv
		ln -sf ../../deps "$oaDir"/deps
	fi
}

function post_clean {
	appsDir="$BASEDIR/apps"	
	rm -Rf "$appsDir"
}

case "$1" in
	"pre_get-deps")
		pre_get-deps;;
	"post_get-deps")
		post_get-deps;;
	"pre_compile")
		pre_compile;;
	"post_compile")
		post_compile;;
	"post_clean")
		post_clean;;
esac
