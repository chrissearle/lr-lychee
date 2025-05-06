-- Main.lua
-- This is the main script for the Web Gallery Sync plugin.

local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'

-- Function to synchronize photos to the web gallery
local function syncToWebGallery()
    LrDialogs.message("Syncing to Web Gallery", "This feature is under development.")
end

-- Add the function to the menu item
LrTasks.startAsyncTask(syncToWebGallery)