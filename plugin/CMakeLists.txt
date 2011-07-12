
# function to build tarantool plugins
#
function(tarantool_plugin plugin)
  set (plugin_sources ${ARGV})
  list(REMOVE_ITEM plugin_sources ${plugin})

  add_library(tnt_${plugin} SHARED ${plugin_sources})

  set_target_properties(tnt_${plugin} PROPERTIES COMPILE_FLAGS
    "${core_cflags} " PREFIX "")

  install (TARGETS tnt_${plugin} DESTINATION lib/tarantool)
endfunction()

foreach (plugin ${TARANTOOL_PLUGINS})
  add_subdirectory(${plugin})
endforeach()
