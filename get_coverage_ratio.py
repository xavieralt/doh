#!/usr/bin/env python3

import re
import os.path
import argparse
import datetime
import logging
from collections import defaultdict, OrderedDict
import requests
from lxml import etree, html

_logger = logging.getLogger('coverage-ratio')

def _hasclass(context, *cls):
    """ Checks if the context node has all the classes passed as arguments
    """
    node_classes = set(context.context_node.attrib.get('class', '').split())
    return node_classes.issuperset(cls)

xpath_utils = etree.FunctionNamespace(None)
xpath_utils['hasclass'] = _hasclass

def coverage_per_module(coverage_url, strip=None, output_ratio=1.0):
    _logger.debug('Going to fetch url: %s', coverage_url)
    if os.path.isfile(coverage_url):
        html_data = open(coverage_url, 'rb').read()
    else:
        html_request = requests.get(coverage_url)
        html_data = html_request.text
    html_node = html.fromstring(html_data)

    # Gather coverage date
    coverage_date = datetime.datetime.now().strftime('%Y-%m-%d')
    for footer in html_node.xpath("//div[@id='footer']"):
        footer_str = str(etree.tostring(footer, encoding='utf-8'), 'utf-8').replace('\n', '')
        footer_match = re.match('.*created at (?P<coverage_date>[0-9]{4}-[0-9]{2}-[0-9]{2}).*', footer_str)
        if footer_match:
            coverage_date = footer_match.group('coverage_date')

    #  {module: [(file, branches_done, branches_total), ...], ...}
    covdata = defaultdict(list)
    for file_row in html_node.xpath("//tr[@class='file']"):
        file_name_cells = file_row.xpath("td[hasclass('name')]")
        file_ratio_cells = file_row.xpath("td[@data-ratio]")
        file_name = None
        ratios = []
        if file_name_cells and file_ratio_cells:
            for node in file_name_cells[0]:
                if node.tag == 'a':
                    file_name = node.text
                    break
            ratio_values = file_ratio_cells[0].get('data-ratio')
            ratios = [int(x) for x in (ratio_values or '').split()]
        if file_name and len(ratios) >= 2:
            fnparts = file_name.split('/')
            if strip and strip > 0:
                fnparts = fnparts[strip:]
            module = fnparts[0]
            module_file = '/'.join(fnparts)
            covdata[module].append((module_file, ratios[0], ratios[1]))

    modsratio = {}
    for module in sorted(covdata):
        done, total = 0, 0
        _logger.debug('module: %s', module)
        for file_name, file_done, file_total in covdata[module]:
            _logger.debug('- file: %s (%d / %d)', file_name, file_done, file_total)
            done += file_done
            total += file_total
        ratio = round(done * 100. / total, 2) * output_ratio if total else 0
        format_ = "%.4f" if output_ratio == 0.01 else "%.2f"
        modsratio[module] = float(format_ % (ratio,))

    return coverage_date, covdata, modsratio

def coverage_summary(coverage_date, covdata, output_ratio=1.0):
    all_done, all_total = 0, 0
    for module in sorted(covdata):
        done, total = 0, 0
        _logger.debug('module: %s', module)
        for file_name, file_done, file_total in covdata[module]:
            _logger.debug('- file: %s (%d / %d)', file_name, file_done, file_total)
            done += file_done
            total += file_total
        ratio = round(done * 100. / total, 2) * output_ratio if total else 0
        _logger.debug('module %s (summary): done: %d, total: %d = %.2f%%',
            module, done, total, ratio)
        format_ = "%s,%s,%.4f" if output_ratio == 0.01 else "%s,%s,%.2f"
        print(format_ % (coverage_date, module, ratio))
        all_done += done
        all_total += total
    _logger.debug('TOTAL (summary): done, %d, total: %d = %.2f%%',
        all_done, all_total, round(all_done * 100. / all_total, 2))

if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser('get coverage ratio per odoo module')
    parser.add_argument('--strip', '-p', type=int,
        help='Strip prefix containing {num} slashes')
    parser.add_argument('--ratio', '-r', type=float,
        help='Number ratio: 1 for range 0-100, 0.01 for range 0.01 to 1.0',
        default=0.01)
    parser.add_argument('--debug', action='store_true', help='Output debug infos')
    parser.add_argument('coverage_url')
    args = parser.parse_args()
    if args.debug:
        _logger.setLevel(logging.DEBUG)
    coverage_date, covdata, modsratio = coverage_per_module(args.coverage_url, args.strip, args.ratio)
    coverage_summary(coverage_date, covdata, output_ratio=args.ratio)
