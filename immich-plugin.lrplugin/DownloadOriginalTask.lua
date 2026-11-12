require("ImmichAPI")
require("MetadataTask")

--[[
    DownloadOriginalTask - fetch the full-size original from Immich for the selected photos.

    Companion to the sync's thumbnail-preview mode: previews are imported stamped with their
    Immich asset ID, and this action downloads the real file (RAW or rendered original,
    honoring the stack-handling preference) next to the photo's current file. Photos without
    a stored Immich ID are skipped. Existing files are never overwritten.
]]

return {
    LrTasks.startAsyncTask(function()
        if not Util.ensureConnected() then
            return
        end

        if prefs.syncStackHandling == nil then
            prefs.syncStackHandling = "primary"
        end

        local catalog = LrApplication.activeCatalog()
        local photos = catalog:getTargetPhotos()
        if not photos or #photos == 0 then
            LrDialogs.message("No photos selected", "Select one or more photos to download from Immich.", "info")
            return
        end

        local immich = ImmichAPI:new(prefs.url, prefs.apiKey)
        if not immich:checkConnectivity() then
            ErrorHandler.handleError(
                "Immich connection not working. Check URL and API key in the import configuration.",
                "DownloadOriginalTask: connectivity check failed"
            )
            return
        end

        local progress = LrProgressScope({ title = "Downloading originals from Immich...", caption = "Starting..." })
        local total = #photos
        local downloaded, stacked, skippedNoId, skippedExists, failed = 0, 0, 0, 0, 0
        local failures = {}

        for i, photo in ipairs(photos) do
            if progress:isCanceled() then
                break
            end
            local filename = photo:getFormattedMetadata("fileName")
            local assetId = MetadataTask.getAnyImmichAssetId(photo)
            if Util.nilOrEmpty(assetId) then
                skippedNoId = skippedNoId + 1
            else
                local repId = immich:resolveStackAssetId(assetId, prefs.syncStackHandling)
                local info = immich:getAssetInfo(repId)
                local originalName = (info and info.originalFileName) or nil
                local photoPath = photo:getRawMetadata("path")
                if Util.nilOrEmpty(originalName) or Util.nilOrEmpty(photoPath) then
                    failed = failed + 1
                    table.insert(failures, filename .. " (asset info or path unavailable)")
                else
                    local dest = LrPathUtils.child(LrPathUtils.parent(photoPath), originalName)
                    if LrFileUtils.exists(dest) then
                        skippedExists = skippedExists + 1
                    elseif immich:downloadAssetToFile(repId, dest, false) then
                        downloaded = downloaded + 1
                        -- Import the original stacked above the preview photo, so the RAW
                        -- is on top of the stack and "edit" opens the full-size file.
                        local ok, err = LrTasks.pcall(function()
                            catalog:withWriteAccessDo("Immich: stack original", function()
                                catalog:addPhoto(dest, photo, "above")
                            end, { timeout = 30 })
                        end)
                        if ok then
                            stacked = stacked + 1
                        else
                            log:warn("DownloadOriginalTask: stacking failed for " .. filename .. ": " .. tostring(err))
                        end
                    else
                        failed = failed + 1
                        table.insert(failures, filename .. " (download failed)")
                    end
                end
            end
            progress:setPortionComplete(i, total)
            progress:setCaption(string.format("Downloading (%d of %d)", i, total))
        end
        progress:done()

        local lines = {
            string.format("Downloaded: %d", downloaded),
            string.format("Stacked above preview: %d", stacked),
            string.format("Already present: %d", skippedExists),
            string.format("No Immich ID: %d", skippedNoId),
            string.format("Failed: %d", failed),
        }
        LrDialogs.message(
            "Immich original download finished",
            table.concat(lines, "\n") .. (#failures > 0 and ("\n\n" .. table.concat(failures, "\n")) or ""),
            failed > 0 and "warning" or "info"
        )
    end),
}
