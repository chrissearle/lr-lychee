-- Main.lua
-- This is the main script for the Web Gallery Sync plugin.

local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

local logger = require 'Logger'

-- Log plugin startup
logger:info("Lychee plugin started")
