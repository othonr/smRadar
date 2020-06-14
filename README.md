# Scrap Mechanic Simple Radar
#### Since the devs haven't added this feature yet, i made my own...
This adds a very simple radar interface to the survival version of the game

The Radar:

![Radar interface](/sm_02.jpg)

Steam Workshop link: https://steamcommunity.com/sharedfiles/filedetails/?id=2128739946

It also adds the chat command `/map` so that you can offset where you want the radar to point to

The usage is as follows:

`/map home` : Will zero the radar to where you are standing, otherwise it will use the crash site as home

I am planing on making a better interface with graphical elements, but i'm having a bit of trouble with it, since i'm confident in python but the game comes in lua, if you want to help me with that send me an email.

Also a little bit of the road map for this tool (if the devs don't make their own before):

- Make an interface
- Add multiplayer support
- Save positions and remember them for each save
- Add beacons to mark stuff
- Make a hotkey instead of chat commands
- Add enemy detection

## To install: 
```
Just clone or download this repository
Replace the files in your Scrap Mechanic instalation directory
(BackUp your original ones first, obviously)
```


If you are curious on how it works, it is just some basic trigonometry:
![Math for the radar](/sm_03.png)
