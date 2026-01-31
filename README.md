# Session Manger
Search in all open nvim sessions across your tmux sessions
also you can mark as many files as you want and move in between them 


# TODO

[ ] do tests
[ ] make it useable through lazy


# How to use ?

clone put in `~/.config/nvim/lua/`


then inside `init.lau` add

```
{
	"husseinmirzaki/nvim-tmux-integration",
	name = "session_manager",
	config = function()
		require("session_manager").setup()
	end
}
```
