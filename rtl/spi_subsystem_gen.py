#!/usr/bin/env python3

# USAGE : 
# python3 rtl/spi_subsystem_gen.py rtl/spi_subsystem.sv.tpl rtl/spi_subsystem.sv
# uncomment the correct self.interfaces and self.periferals

import sys
from mako.template import Template


# -------------------------------------------------------
# Minimal mock objects to satisfy the template
# -------------------------------------------------------

class PeripheralDomain:

    def __init__(self):
        self.interfaces = ["obi", "axi"]
        #self.interfaces = ["no_obi", "axi"]
        #self.interfaces = ["no_obi", "no_axi"]
        #self.interfaces = ["obi", "no_axi"]
        #self.peripherals = ["w25q128jw_controller"]
        self.peripherals = ["no_w25q128jw_controller"]

    def contains_interface(self, name):
        return name in self.interfaces

    def contains_peripheral(self, name):
        return name in self.peripherals


class XHeep:

    def get_base_peripheral_domain(self):
        return PeripheralDomain()


# -------------------------------------------------------
# Main
# -------------------------------------------------------

def main():

    if len(sys.argv) != 3:
        print("Usage: python spi_subsystem_gen.py input.tpl output.sv")
        sys.exit(1)

    tpl_file = sys.argv[1]
    out_file = sys.argv[2]

    xheep = XHeep()

    template = Template(filename=tpl_file)
    rendered = template.render(xheep=xheep)

    with open(out_file, "w") as f:
        f.write(rendered)

    print(f"Generated {out_file}")


if __name__ == "__main__":
    main()