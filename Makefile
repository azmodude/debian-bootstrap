destroy:
	vagrant destroy -f
clean:
	vagrant destroy -f && vagrant up
ssh:
	TERM=xterm-256color vagrant ssh
