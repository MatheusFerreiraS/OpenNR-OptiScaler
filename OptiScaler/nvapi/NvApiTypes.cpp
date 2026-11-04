#include "pch.h"
#include "NvApiTypes.h"

#include <nvapi_interface.h>

NvApiTypes::NvApiTypes()
{
    for (const auto& entry : nvapi_interface_table)
    {
        lookupTable[entry.func] = entry.id;
        nameTable[entry.id] = entry.func;
    }
}
NvApiTypes& NvApiTypes::Instance()
{
    static NvApiTypes instance;
    return instance;
}

unsigned int NvApiTypes::getId(const std::string& name) const
{
    auto it = lookupTable.find(name);
    if (it != lookupTable.end())
    {
        return it->second;
    }
    LOG_TRACE("Not a known nvapi interface");
    return 0;
}

std::string NvApiTypes::getName(unsigned int id) const
{
    auto it = nameTable.find(id);
    return it != nameTable.end() ? it->second : "unknown";
}
