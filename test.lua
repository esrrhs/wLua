function alloc_id(index)
    return ((index & 0xffffffff) << 32) | 1
end

local src = {}
local index = os.time()
for i = 1, 30000 do
    local id = alloc_id(index)
    index = index + 1
    table.insert(src, id)
end

local index = 1
while true do
    local dst = {}
    local begin = os.time()
    for k, v in ipairs(src) do
        dst[v] = tostring(index)
        index = index + 1
    end
    print("cost " .. os.time() - begin)
end
