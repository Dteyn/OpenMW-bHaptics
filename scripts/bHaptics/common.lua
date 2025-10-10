if require("openmw.core").API_REVISION < 76 then
    error("OpenMW 0.49.0 or newer is required!")
end

local MOD_ID = "OpenMW-bHaptics"

return {
    MOD_ID = MOD_ID,
}
