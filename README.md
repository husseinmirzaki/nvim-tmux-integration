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
	config = function()
		require("nvim-tmux-integration").setup()
	end,
}
```

* Open session manager with `<leader>sm`
* Add current file to jump list `<leader>sa` 
* Show list of all selected files `<leader>sl`
* Search inside session files and open that session's file on that specific line `<leader>sf`
