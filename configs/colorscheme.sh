if [ "${TERM:0:5}" == "xterm" ]; then
	export PS1='\[\033[01;36m\][HOME] \u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
	    else
	export PS1='[HOME] \u@\h:\$ '
fi
