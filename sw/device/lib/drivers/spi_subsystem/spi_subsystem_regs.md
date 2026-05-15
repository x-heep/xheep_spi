<table class="regdef" id="Reg_control">
 <tr>
  <th class="regdef" colspan=5>
   <div>spi_subsystem.CONTROL @ 0x0</div>
   <div><p>Control register</p></div>
   <div>Reset default = 0x0, mask 0x3</div>
  </th>
 </tr>
<tr><td colspan=5><table class="regpic"><tr><td class="bitnum">31</td><td class="bitnum">30</td><td class="bitnum">29</td><td class="bitnum">28</td><td class="bitnum">27</td><td class="bitnum">26</td><td class="bitnum">25</td><td class="bitnum">24</td><td class="bitnum">23</td><td class="bitnum">22</td><td class="bitnum">21</td><td class="bitnum">20</td><td class="bitnum">19</td><td class="bitnum">18</td><td class="bitnum">17</td><td class="bitnum">16</td></tr><tr><td class="unused" colspan=16>&nbsp;</td>
</tr>
<tr><td class="bitnum">15</td><td class="bitnum">14</td><td class="bitnum">13</td><td class="bitnum">12</td><td class="bitnum">11</td><td class="bitnum">10</td><td class="bitnum">9</td><td class="bitnum">8</td><td class="bitnum">7</td><td class="bitnum">6</td><td class="bitnum">5</td><td class="bitnum">4</td><td class="bitnum">3</td><td class="bitnum">2</td><td class="bitnum">1</td><td class="bitnum">0</td></tr><tr><td class="unused" colspan=14>&nbsp;</td>
<td class="fname" colspan=1 style="font-size:16.666666666666668%">A2F_CTR_POWERON_EN</td>
<td class="fname" colspan=1 style="font-size:42.857142857142854%">USE_AXI</td>
</tr></table></td></tr>
<tr><th width=5%>Bits</th><th width=5%>Type</th><th width=5%>Reset</th><th>Name</th><th>Description</th></tr><tr><td class="regbits">0</td><td class="regperm">rw</td><td class="regrv">0x0</td><td class="regfn">USE_AXI</td><td class="regde"><p>selects between the two flash controllers, as flash master and interrupt source</p></td><tr><td class="regbits">1</td><td class="regperm">rw</td><td class="regrv">0x0</td><td class="regfn">A2F_CTR_POWERON_EN</td><td class="regde"><p>enables the power-on sfm in axi_to_flash_controller</p></td></table>
<br>
